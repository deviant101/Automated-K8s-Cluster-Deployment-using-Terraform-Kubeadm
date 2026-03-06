#!/bin/bash
# =============================================================================
# master-init.sh
# =============================================================================
# Run ONCE on the control-plane node via Terraform remote-exec provisioner.
# Assumes common-node-setup.sh has already completed (sentinel file present).
#
# Steps:
#   1. Wait for cloud-init / common-setup to finish
#   2. Run kubeadm init
#   3. Configure kubectl for the admin user
#   4. Install Cilium CNI via Cilium CLI
#   5. Wait for the cluster to become healthy
#   6. Write the kubeadm join command to a file for workers to consume
#
# Usage:
#   sudo bash master-init.sh <pod_cidr> <service_cidr> <k8s_version> <admin_user> <cilium_version>
#
# Ref:
#   https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
#   https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/
# =============================================================================

set -euo pipefail

# ── Arguments ────────────────────────────────────────────────────────────────
POD_CIDR="${1:-10.10.0.0/16}"
SERVICE_CIDR="${2:-10.96.0.0/12}"
K8S_VERSION="${3:-1.32}"
ADMIN_USER="${4:-azureuser}"
CILIUM_VERSION="${5:-1.17.2}"
# ─────────────────────────────────────────────────────────────────────────────

LOG_FILE="/var/log/k8s-master-init.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== [$(date)] Starting control-plane bootstrap ==="
echo "    POD_CIDR       : $POD_CIDR"
echo "    SERVICE_CIDR   : $SERVICE_CIDR"
echo "    K8S_VERSION    : $K8S_VERSION"
echo "    ADMIN_USER     : $ADMIN_USER"
echo "    CILIUM_VERSION : $CILIUM_VERSION"

# ─────────────────────────────────────────────────────────────────────────────
# 1.  Wait for cloud-init / common-setup to complete
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Waiting for common-node-setup to complete ==="
TIMEOUT=600
ELAPSED=0
until [[ -f /var/lib/k8s-common-setup-done ]]; do
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "ERROR: Timed out waiting for common-node-setup to complete" >&2
    exit 1
  fi
  echo "  ... still waiting (${ELAPSED}s elapsed)"
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done
echo "=== Common setup confirmed complete ==="

# Verify containerd is running
systemctl is-active --quiet containerd || (echo "ERROR: containerd not running" >&2; exit 1)

# ─────────────────────────────────────────────────────────────────────────────
# 2.  Determine the private IP of this node
#     Used as the advertise address so the API server binds on the correct
#     interface inside the Azure VNet.
# ─────────────────────────────────────────────────────────────────────────────
# Prefer eth0 private IP; fall back to first non-loopback interface
PRIVATE_IP=$(ip -4 addr show eth0 2>/dev/null \
  | grep -oP '(?<=inet\s)\d+(\.\d+){3}' \
  | head -1)
if [[ -z "$PRIVATE_IP" ]]; then
  PRIVATE_IP=$(hostname -I | awk '{print $1}')
fi
echo "=== Control-plane private IP: $PRIVATE_IP ==="

# ─────────────────────────────────────────────────────────────────────────────
# 3.  kubeadm init
#     --skip-phases=addon/kube-proxy  →  Cilium will replace kube-proxy
#     --pod-network-cidr              →  must not overlap with VNet or service CIDR
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Running kubeadm init ==="
kubeadm init \
  --pod-network-cidr="${POD_CIDR}" \
  --service-cidr="${SERVICE_CIDR}" \
  --apiserver-advertise-address="${PRIVATE_IP}" \
  --skip-phases=addon/kube-proxy \
  --upload-certs \
  2>&1 | tee /var/log/kubeadm-init.log

echo "=== kubeadm init complete ==="

# ─────────────────────────────────────────────────────────────────────────────
# 4.  Configure kubectl
# ─────────────────────────────────────────────────────────────────────────────
# For root (used by this script)
export KUBECONFIG=/etc/kubernetes/admin.conf

# For the admin OS user (survives SSH sessions)
ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
mkdir -p "${ADMIN_HOME}/.kube"
cp /etc/kubernetes/admin.conf "${ADMIN_HOME}/.kube/config"
chown -R "${ADMIN_USER}:${ADMIN_USER}" "${ADMIN_HOME}/.kube"

echo "=== kubectl configured for user $ADMIN_USER ==="

# ─────────────────────────────────────────────────────────────────────────────
# 5.  Install Cilium CLI
#     https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#install-the-cilium-cli
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Installing Cilium CLI ==="

CLI_ARCH="amd64"
if [[ "$(uname -m)" == "aarch64" ]]; then
  CLI_ARCH="arm64"
fi

# Download the latest stable Cilium CLI release
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CILIUM_CLI_TARBALL="cilium-linux-${CLI_ARCH}.tar.gz"

curl -fsSL --retry 5 --retry-delay 5 \
  "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/${CILIUM_CLI_TARBALL}" \
  -o "/tmp/${CILIUM_CLI_TARBALL}"

curl -fsSL --retry 5 --retry-delay 5 \
  "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/${CILIUM_CLI_TARBALL}.sha256sum" \
  -o "/tmp/${CILIUM_CLI_TARBALL}.sha256sum"

# Verify checksum
pushd /tmp
sha256sum --check "${CILIUM_CLI_TARBALL}.sha256sum"
popd

tar -xzf "/tmp/${CILIUM_CLI_TARBALL}" -C /usr/local/bin cilium
rm -f "/tmp/${CILIUM_CLI_TARBALL}" "/tmp/${CILIUM_CLI_TARBALL}.sha256sum"

cilium version --client
echo "=== Cilium CLI installed ==="

# ─────────────────────────────────────────────────────────────────────────────
# 6.  Install Cilium CNI
#     --set k8sServiceHost        →  control-plane private IP (kube-proxy replacement)
#     --set k8sServicePort        →  kube-apiserver port
#     --set kubeProxyReplacement  →  full eBPF-based kube-proxy replacement
#     --set ipam.mode             →  cluster-pool for pod CIDR management
#     --set tunnel                →  VXLAN tunnel mode (compatible with Azure VNet)
#
#     Ref: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Installing Cilium CNI v${CILIUM_VERSION} ==="

KUBECONFIG=/etc/kubernetes/admin.conf \
cilium install \
  --version "${CILIUM_VERSION}" \
  --set k8sServiceHost="${PRIVATE_IP}" \
  --set k8sServicePort="6443" \
  --set kubeProxyReplacement=true \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="${POD_CIDR}" \
  --set tunnelProtocol=vxlan \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=false

echo "=== Cilium install command dispatched — waiting for agent readiness ==="

# ─────────────────────────────────────────────────────────────────────────────
# 7.  Wait for Cilium to become healthy
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Waiting for Cilium status ==="
KUBECONFIG=/etc/kubernetes/admin.conf \
cilium status --wait --wait-duration 10m || {
  echo "WARNING: cilium status timed out — check 'cilium status' manually"
}

# ─────────────────────────────────────────────────────────────────────────────
# 8.  Wait for the control-plane node to reach Ready state
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Waiting for control-plane node to become Ready ==="
TIMEOUT=300
ELAPSED=0
until KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes 2>/dev/null \
  | grep -qE "$(hostname).*Ready"; do
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "WARNING: Timed out waiting for node Ready state"
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes
    break
  fi
  echo "  ... waiting for node Ready (${ELAPSED}s)"
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -n kube-system

# ─────────────────────────────────────────────────────────────────────────────
# 9.  Generate the kubeadm join command for worker nodes
#     Written to a file that Terraform will scp back to the local machine.
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Generating worker join command ==="
JOIN_CMD=$(kubeadm token create --print-join-command)

cat > "/home/${ADMIN_USER}/join-command.sh" <<JOIN
#!/bin/bash
# Auto-generated by master-init.sh — $(date)
set -euo pipefail
${JOIN_CMD}
JOIN

chmod 600 "/home/${ADMIN_USER}/join-command.sh"
chown "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/join-command.sh"

echo "=== Join command saved to /home/${ADMIN_USER}/join-command.sh ==="

# ─────────────────────────────────────────────────────────────────────────────
# 10. Copy kubeconfig to admin user home for external kubectl access
# ─────────────────────────────────────────────────────────────────────────────
cp /etc/kubernetes/admin.conf "/home/${ADMIN_USER}/admin.kubeconfig"
chown "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/admin.kubeconfig"

echo "=== [$(date)] Control-plane bootstrap complete ==="
echo ""
echo "Cluster info:"
KUBECONFIG=/etc/kubernetes/admin.conf kubectl cluster-info
echo ""
echo "Nodes:"
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide

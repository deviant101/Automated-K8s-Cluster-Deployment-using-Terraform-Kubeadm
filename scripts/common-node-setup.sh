#!/bin/bash
# =============================================================================
# common-node-setup.sh
# =============================================================================
# Runs on EVERY cluster node (both control-plane and workers) via cloud-init
# (Azure custom_data).  Sets up the prerequisites required by kubeadm before
# the cluster bootstrap phase begins.
#
# This file is processed by Terraform templatefile() — Terraform substitutes
# the lowercase variables below. All other shell variables use the plain $VAR
# (no curly braces) form to avoid conflicts with Terraform template syntax.
#
# Terraform template variables injected by templatefile():
#   k8s_version  → Kubernetes minor version,   e.g. "1.32"
#   k8s_minor    → Apt package version string,  e.g. "1.32.3-1.1" (or "")
#   node_role    → "master" or "worker"
#
# Based on the official kubeadm installation documentation:
#   https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
#   https://kubernetes.io/docs/setup/production-environment/container-runtimes/
#
# Tested on Ubuntu 22.04 LTS (Jammy)
# =============================================================================

set -euo pipefail

# ── Variables resolved by Terraform templatefile() ───────────────────────────
K8S_VERSION="${k8s_version}"          # e.g.  1.32
K8S_MINOR="${k8s_minor}"              # e.g.  1.32.3-1.1  (exact apt pkg version)
NODE_ROLE="${node_role}"              # "master" or "worker"
# ─────────────────────────────────────────────────────────────────────────────

LOG_FILE="/var/log/k8s-common-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== [$(date)] Starting common Kubernetes node setup (role: $NODE_ROLE) ==="

# ─────────────────────────────────────────────────────────────────────────────
# 1.  Hostname — use the Azure-assigned hostname (already set by Azure)
# ─────────────────────────────────────────────────────────────────────────────
hostnamectl set-hostname "$(hostname)"
echo "Hostname: $(hostname)"

# ─────────────────────────────────────────────────────────────────────────────
# 2.  System updates and baseline utilities
# ─────────────────────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  socat \
  conntrack \
  ipset \
  ipvsadm \
  jq \
  net-tools \
  wget

echo "=== Baseline packages installed ==="

# ─────────────────────────────────────────────────────────────────────────────
# 3.  Disable swap (kubeadm requirement)
# ─────────────────────────────────────────────────────────────────────────────
swapoff -a
# Persist across reboots — comment out any swap lines in /etc/fstab
sed -i '/\sswap\s/s/^/#/' /etc/fstab
echo "=== Swap disabled ==="

# ─────────────────────────────────────────────────────────────────────────────
# 4.  Kernel modules required by containerd and Kubernetes networking
#     overlay   – containerd overlay filesystem
#     br_netfilter – enables iptables to process bridged traffic
# ─────────────────────────────────────────────────────────────────────────────
cat <<'EOF' > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter
echo "=== Kernel modules loaded ==="

# ─────────────────────────────────────────────────────────────────────────────
# 5.  Sysctl parameters required by Kubernetes networking
# ─────────────────────────────────────────────────────────────────────────────
cat <<'EOF' > /etc/sysctl.d/99-kubernetes.conf
# Allow iptables to see bridged traffic
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1

# Enable IPv4 forwarding
net.ipv4.ip_forward                 = 1

# Cilium — increase conntrack table size for high-traffic clusters
net.netfilter.nf_conntrack_max      = 1048576

# Increase inotify limits for kubelets watching many directories
fs.inotify.max_user_watches         = 524288
fs.inotify.max_user_instances       = 512
EOF

sysctl --system
echo "=== Sysctl parameters applied ==="

# ─────────────────────────────────────────────────────────────────────────────
# 6.  Install containerd
#     Source: official Docker apt repository (provides containerd.io)
# ─────────────────────────────────────────────────────────────────────────────
install -m 0755 -d /etc/apt/keyrings

# Docker apt repo signing key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Docker apt repo (only containerd.io is installed from here)
ARCH=$(dpkg --print-architecture)
CODENAME=$(lsb_release -cs)
echo \
  "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y containerd.io
echo "=== containerd installed ==="

# ─────────────────────────────────────────────────────────────────────────────
# 7.  Configure containerd — enable CRI plugin and SystemdCgroup
#     kubeadm requires SystemdCgroup = true so kubelet and containerd agree
#     on the cgroup driver.
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Switch to SystemdCgroup driver
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Pause image should match the kubeadm version
PAUSE_VERSION="3.10"
sed -i "s|sandbox_image = .*|sandbox_image = \"registry.k8s.io/pause:$PAUSE_VERSION\"|" \
  /etc/containerd/config.toml

systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd

# Verify containerd is running
if ! systemctl is-active --quiet containerd; then
  echo "ERROR: containerd failed to start" >&2
  journalctl -u containerd --no-pager --lines=50
  exit 1
fi
echo "=== containerd configured and running ==="

# ─────────────────────────────────────────────────────────────────────────────
# 8.  Install kubeadm, kubelet, kubectl
#     Source: official Kubernetes apt repository (pkgs.k8s.io)
#     Ref: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#installing-kubeadm-kubelet-and-kubectl
# ─────────────────────────────────────────────────────────────────────────────

# Add Kubernetes apt repo signing key
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v$K8S_VERSION/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add Kubernetes apt repository
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v$K8S_VERSION/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -y

# Install specific version if provided, otherwise latest in the minor stream
if [[ -n "$K8S_MINOR" ]]; then
  apt-get install -y \
    "kubelet=$K8S_MINOR" \
    "kubeadm=$K8S_MINOR" \
    "kubectl=$K8S_MINOR"
else
  apt-get install -y kubelet kubeadm kubectl
fi

# Pin versions so apt-get upgrade doesn't inadvertently upgrade Kubernetes
apt-mark hold kubelet kubeadm kubectl

systemctl enable --now kubelet

K8S_PKG_LABEL="${k8s_minor}"
if [[ -z "$K8S_PKG_LABEL" ]]; then K8S_PKG_LABEL="latest"; fi
echo "=== kubeadm / kubelet / kubectl installed and pinned (version: $K8S_PKG_LABEL) ==="

# ─────────────────────────────────────────────────────────────────────────────
# 9.  Write a sentinel file so provisioners can wait for cloud-init to finish
# ─────────────────────────────────────────────────────────────────────────────
touch /var/lib/k8s-common-setup-done
echo "=== [$(date)] Common node setup complete ==="



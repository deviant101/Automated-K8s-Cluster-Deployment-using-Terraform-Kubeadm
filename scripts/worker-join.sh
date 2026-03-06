#!/bin/bash
# =============================================================================
# worker-join.sh
# =============================================================================
# Run on EACH worker node via Terraform remote-exec provisioner.
# Assumes:
#   - common-node-setup.sh has already completed on this node (sentinel file)
#   - join-command.sh has been copied to /home/<ADMIN_USER>/join-command.sh
#     by the Terraform file provisioner
#
# Usage:
#   sudo bash worker-join.sh <admin_user>
#
# Ref:
#   https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#join-nodes
# =============================================================================

set -euo pipefail

ADMIN_USER="${1:-azureuser}"

LOG_FILE="/var/log/k8s-worker-join.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== [$(date)] Starting worker node join ==="
echo "    ADMIN_USER: $ADMIN_USER"

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
# 2.  Verify the join script exists
# ─────────────────────────────────────────────────────────────────────────────
JOIN_SCRIPT="/home/${ADMIN_USER}/join-command.sh"

if [[ ! -f "$JOIN_SCRIPT" ]]; then
  echo "ERROR: Join script not found at $JOIN_SCRIPT" >&2
  exit 1
fi

cat "$JOIN_SCRIPT"

# ─────────────────────────────────────────────────────────────────────────────
# 3.  Execute the kubeadm join command
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Running kubeadm join ==="
chmod +x "$JOIN_SCRIPT"
bash "$JOIN_SCRIPT" 2>&1 | tee /var/log/kubeadm-join.log
echo "=== kubeadm join complete ==="

# ─────────────────────────────────────────────────────────────────────────────
# 4.  Verify kubelet is running
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Checking kubelet status ==="
TIMEOUT=120
ELAPSED=0
until systemctl is-active --quiet kubelet; do
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "WARNING: kubelet is not active after join"
    journalctl -u kubelet --no-pager --lines=30
    break
  fi
  echo "  ... waiting for kubelet (${ELAPSED}s)"
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

systemctl status kubelet --no-pager || true

echo "=== [$(date)] Worker node join complete ==="
echo "    Check node status on master: kubectl get nodes"

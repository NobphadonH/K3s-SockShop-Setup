#!/usr/bin/env bash
set -euo pipefail

# Setup kubectl access to a remote k3s cluster by pulling k3s.yaml from the k3s node
# Usage:
#   ./setup_k3s_kubeconfig.sh <K3S_PRIVATE_IP> [SSH_USER] [KEY_PATH]
#
# Examples:
#   chmod +x setup_k3s_kubeconfig.sh
#   ./setup_k3s_kubeconfig.sh 10.0.2.117
#   ./setup_k3s_kubeconfig.sh 10.0.2.117 ubuntu ~/.ssh/k3s.pem

K3S_IP="${1:-}"
SSH_USER="${2:-ubuntu}"
KEY_PATH="${3:-$HOME/.ssh/k3s.pem}"

OUT_KUBECONFIG="$HOME/k3s.yaml"

if [[ -z "$K3S_IP" ]]; then
  echo "ERROR: Missing K3S_PRIVATE_IP"
  echo "Usage: $0 <K3S_PRIVATE_IP> [SSH_USER] [KEY_PATH]"
  exit 1
fi

if [[ ! -f "$KEY_PATH" ]]; then
  echo "ERROR: Key file not found: $KEY_PATH"
  exit 2
fi

echo "[1/5] Locking down key permissions: $KEY_PATH"
chmod 400 "$KEY_PATH"

echo "[2/5] Copying kubeconfig from k3s node (${SSH_USER}@${K3S_IP})..."
scp -i "$KEY_PATH" -o StrictHostKeyChecking=accept-new \
  "${SSH_USER}@${K3S_IP}:/etc/rancher/k3s/k3s.yaml" \
  "$OUT_KUBECONFIG"

echo "[3/5] Rewriting kubeconfig server address to use: $K3S_IP"
sed -i "s/127.0.0.1/${K3S_IP}/g" "$OUT_KUBECONFIG"

echo "[4/5] Setting KUBECONFIG "
# echo "export KUBECONFIG=\"$OUT_KUBECONFIG\"" >> ~/.bashrc
echo "export KUBECONFIG=\"$OUT_KUBECONFIG\""
export KUBECONFIG="$OUT_KUBECONFIG"
#source ~/.bashrc

echo "[5/5] Testing access: kubectl get nodes"
kubectl get nodes


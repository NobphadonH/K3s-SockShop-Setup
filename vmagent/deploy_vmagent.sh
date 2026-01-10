#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <victoriametrics_private_ip> [port]"
  exit 1
fi

VM_IP="$1"
VM_PORT="${2:-8428}"
REMOTE_WRITE_URL="http://$VM_IP:$VM_PORT/api/v1/write"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Using remote_write: $REMOTE_WRITE_URL"

helm repo add victoria-metrics https://victoriametrics.github.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update >/dev/null

kubectl create ns monitoring >/dev/null 2>&1 || true

# Render values file (do NOT edit tracked file)
sed "s|__REMOTE_WRITE_URL__|$REMOTE_WRITE_URL|g" \
  "$SCRIPT_DIR/vmagent-values.yaml.tmpl" > "$SCRIPT_DIR/vmagent-values.yaml"

helm upgrade --install vmagent victoria-metrics/victoria-metrics-agent \
  -n monitoring \
  -f "$SCRIPT_DIR/vmagent-values.yaml"

kubectl get pods -n monitoring
kubectl logs -n monitoring deploy/vmagent-victoria-metrics-agent --tail=100

#!/usr/bin/env bash
set -euo pipefail

# Dynamic CPU StressChaos injector (Chaos Mesh)
#
# Example:
#   ./inject_cpu.sh -t carts -d 60s -o ./injection_time.txt
#
# Optional overrides:
#   -c <container>   (default: same as service)
#   -n <name>        (default: <service>-cpu-stress)
#   -s <namespace>   (default: sock-shop)
#   -w <workers>     (default: 1)
#   -l <load>        (default: 90)
#   -k <kubeconfig>  (default: $HOME/k3s.yaml)

SERVICE=""
CONTAINER=""
DURATION=""
NAME=""
NAMESPACE="sock-shop"
OUT_PATH=""
WORKERS="1"
LOAD="90"
KCFG="${HOME}/k3s.yaml"

usage() {
  echo "Usage: $0 -t <service> -d <duration> -o <out_path> [-c <container>] [-n <name>] [-s <namespace>] [-w <workers>] [-l <load>] [-k <kubeconfig>]" >&2
  echo "  service:    deployment label value used by Chaos Mesh selector (labelSelectors.name)" >&2
  echo "  duration:   60s | 2m | 1h | 120 (seconds)" >&2
  exit 1
}

to_seconds() {
  local d="$1"
  if [[ "$d" =~ ^[0-9]+$ ]]; then
    echo "$d"; return
  fi
  if [[ "$d" =~ ^([0-9]+)([smh])$ ]]; then
    local n="${BASH_REMATCH[1]}"
    local u="${BASH_REMATCH[2]}"
    case "$u" in
      s) echo "$n" ;;
      m) echo $((n * 60)) ;;
      h) echo $((n * 3600)) ;;
    esac
    return
  fi
  echo "Unsupported duration format: $d (use forms like 60s, 2m, 1h)" >&2
  exit 2
}

while getopts ":t:c:d:n:s:o:w:l:k:" opt; do
  case "$opt" in
    t) SERVICE="$OPTARG" ;;
    c) CONTAINER="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    n) NAME="$OPTARG" ;;
    s) NAMESPACE="$OPTARG" ;;
    o) OUT_PATH="$OPTARG" ;;
    w) WORKERS="$OPTARG" ;;
    l) LOAD="$OPTARG" ;;
    k) KCFG="$OPTARG" ;;
    *) usage ;;
  esac
done

[[ -n "$SERVICE" ]] || usage
[[ -n "$DURATION" ]] || usage
[[ -n "$OUT_PATH" ]] || usage

# Defaults derived from service
[[ -n "$CONTAINER" ]] || CONTAINER="$SERVICE"
[[ -n "$NAME" ]] || NAME="${SERVICE}-cpu-stress"

# Basic validation
if ! [[ "$WORKERS" =~ ^[0-9]+$ ]] || [[ "$WORKERS" -lt 1 ]]; then
  echo "workers must be a positive integer" >&2; exit 3
fi
if ! [[ "$LOAD" =~ ^[0-9]+$ ]] || [[ "$LOAD" -lt 1 ]] || [[ "$LOAD" -gt 100 ]]; then
  echo "load must be an integer 1-100" >&2; exit 3
fi

KUBECTL=(kubectl)
if [[ -n "${KCFG:-}" ]]; then
  # Only enforce file check if user provided a non-empty value
  [[ -f "$KCFG" ]] || { echo "Kubeconfig not found: $KCFG" >&2; exit 4; }
  KUBECTL+=(--kubeconfig "$KCFG")
fi

# Build YAML dynamically (no static file)
YAML="$(cat <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: StressChaos
metadata:
  name: ${NAME}
  namespace: ${NAMESPACE}
spec:
  duration: "${DURATION}"
  mode: one
  selector:
    labelSelectors:
      name: "${SERVICE}"
  containerNames: ["${CONTAINER}"]
  stressors:
    cpu:
      workers: ${WORKERS}
      load: ${LOAD}
EOF
)"

# 1) Clean any previous StressChaos run
"${KUBECTL[@]}" delete stresschaos "$NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

# 2) Apply generated YAML
echo "$YAML" | "${KUBECTL[@]}" apply -f - >/dev/null

# 3) Record injection start time (Unix timestamp, UTC-based)
EPOCH="$(date -u +%s)"
echo -n "$EPOCH" > "$OUT_PATH"

echo "[$(date +%H:%M:%S)] StressChaos $NAME applied for service=$SERVICE container=$CONTAINER workers=$WORKERS load=$LOAD. Injection time (epoch): $EPOCH"

# 4) Wait for the specified duration, then cleanup
SECONDS_TO_SLEEP="$(to_seconds "$DURATION")"
sleep "$SECONDS_TO_SLEEP"

"${KUBECTL[@]}" delete stresschaos "$NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
echo "[$(date +%H:%M:%S)] StressChaos $NAME deleted after $DURATION."

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./inject_memory.sh \
    -k <kubeconfig> \
    -s <namespace> \
    -n <chaos_name_prefix> \
    -l <label_selector_key=value> \
    -o <output_log_file> \
    --start <Mi> --inc <Mi> --count <N> \
    --step-duration <duration>

Example (leak-like: +30Mi every 30s for 10 steps ~5min):
  ./inject_memory.sh \
    -k ~/k3s.yaml \
    -s sock-shop \
    -n carts-mem-leaklike \
    -l name=carts \
    -o runs/test1/mem_injection.log \
    --start 30Mi --inc 30Mi --count 10 \
    --step-duration 30s

Notes:
  - Uses StressChaos memory stressor to simulate "memory leak-like" progressive growth.
  - Creates a new StressChaos per step (name suffix -s1, -s2, ...), then deletes it.
  - Sizes MUST be in MB
EOF
}

# Defaults
KCFG="$HOME/k3s.yaml"
NAMESPACE="sock-shop"
CHAOS_NAME="mem-leaklike"
LABEL_SELECTOR=""
OUT_PATH="./mem_injection.log"

START_MB="20MB"
INC_MB="20MB"
COUNT="10"
STEP_DURATION="30s"

MODE="one"      # one|all|fixed|fixed-percent|random-max-percent
WORKERS="1"
VALIDATE="false"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -k) KCFG="$2"; shift 2 ;;
    -s) NAMESPACE="$2"; shift 2 ;;
    -n) CHAOS_NAME="$2"; shift 2 ;;
    -l) LABEL_SELECTOR="$2"; shift 2 ;;
    -o) OUT_PATH="$2"; shift 2 ;;
    --start) START_MB="$2"; shift 2 ;;
    --inc) INC_MB="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --step-duration) STEP_DURATION="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --validate) VALIDATE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

# Validate kubeconfig
if [[ -z "$KCFG" ]]; then
  echo "ERROR: kubeconfig required: -k ~/k3s.yaml" >&2
  exit 4
fi
# Expand ~ just in case
KCFG="${KCFG/#\~/$HOME}"
if [[ ! -f "$KCFG" ]]; then
  echo "ERROR: kubeconfig not found: $KCFG" >&2
  exit 4
fi

# Validate selector
if [[ -z "$LABEL_SELECTOR" ]]; then
  echo "ERROR: label selector required: -l key=value (e.g., -l name=carts)" >&2
  exit 4
fi
SEL_KEY="${LABEL_SELECTOR%%=*}"
SEL_VAL="${LABEL_SELECTOR#*=}"
if [[ "$SEL_KEY" == "$SEL_VAL" ]]; then
  echo "ERROR: label selector must be key=value, got: $LABEL_SELECTOR" >&2
  exit 4
fi

# Validate count
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -lt 1 ]]; then
  echo "ERROR: --count must be a positive integer, got: $COUNT" >&2
  exit 4
fi

# Validate sizes are Mi
is_mb() { [[ "$1" =~ ^[0-9]+MB$ ]]; }
if ! is_mb "$START_MB"; then
  echo "ERROR: --start must be like 30MB, got: $START_MB" >&2
  exit 4
fi
if ! is_mb "$INC_MB"; then
  echo "ERROR: --inc must be like 30MB, got: $INC_MB" >&2
  exit 4
fi

start_num="${START_MB%MB}"
inc_num="${INC_MB%MB}"

# Ensure output dir writable
OUT_DIR="$(dirname "$OUT_PATH")"
mkdir -p "$OUT_DIR"
touch "$OUT_PATH" 2>/dev/null || { echo "ERROR: cannot write $OUT_PATH" >&2; exit 10; }

KUBECTL=(kubectl --kubeconfig "$KCFG" -n "$NAMESPACE")

# Helper: timestamps
ts() { date +"[%Y-%m-%d %H:%M:%S]"; }
epoch() { date +%s; }

echo "$(ts) Starting memory leak-like injection" | tee -a "$OUT_PATH"
echo "$(ts) namespace=$NAMESPACE name_prefix=$CHAOS_NAME selector=$SEL_KEY=$SEL_VAL start=$START_MB inc=$INC_MB count=$COUNT step_duration=$STEP_DURATION workers=$WORKERS mode=$MODE" | tee -a "$OUT_PATH"

# Preflight: ensure CRD exists (reliable)
if ! "${KUBECTL[@]}" get crd stresschaos.chaos-mesh.org >/dev/null 2>&1; then
  echo "ERROR: stresschaos.chaos-mesh.org CRD not found. Is Chaos Mesh installed?" | tee -a "$OUT_PATH"
  exit 6
fi

for ((i=1; i<=COUNT; i++)); do
  size_num=$(( start_num + (i-1)*inc_num ))
  SIZE="${size_num}MB"

  STEP_NAME="${CHAOS_NAME}-s${i}"
  START_EPOCH="$(epoch)"

  TMP_YAML="$(mktemp)"
  cat > "$TMP_YAML" <<YAML
apiVersion: chaos-mesh.org/v1alpha1
kind: StressChaos
metadata:
  name: ${STEP_NAME}
  namespace: ${NAMESPACE}
spec:
  mode: ${MODE}
  selector:
    namespaces:
      - ${NAMESPACE}
    labelSelectors:
      ${SEL_KEY}: "${SEL_VAL}"
  stressors:
    memory:
      workers: ${WORKERS}
      size: "${SIZE}"
  duration: "${STEP_DURATION}"
YAML

  echo "$(ts) Step ${i}/${COUNT} apply name=${STEP_NAME} size=${SIZE} start_epoch=${START_EPOCH}" | tee -a "$OUT_PATH"

  if [[ "$VALIDATE" == "false" ]]; then
    "${KUBECTL[@]}" apply --validate=false -f "$TMP_YAML" >/dev/null
  else
    "${KUBECTL[@]}" apply -f "$TMP_YAML" >/dev/null
  fi

  sleep "$STEP_DURATION"

  # cleanup per-step chaos (keeps cluster clean + avoids lingering objects)
  "${KUBECTL[@]}" delete stresschaos "${STEP_NAME}" --ignore-not-found >/dev/null || true
  rm -f "$TMP_YAML"
done

END_EPOCH="$(epoch)"
echo "$(ts) Done end_epoch=${END_EPOCH}. Log saved to: $OUT_PATH" | tee -a "$OUT_PATH"

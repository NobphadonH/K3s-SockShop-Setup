#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./inject_memory.sh \
    -k <kubeconfig> \
    -s <namespace> \
    -n <chaos_name> \
    -l <label_selector_key=value> \
    -o <output_log_file> \
    --steps "200Mi,400Mi,600Mi" \
    --step-duration 40s

What it does:
  Applies a sequence of StressChaos objects (same name), each one increasing
  memory allocation (size) for step-duration, creating "memory leak-like"
  progressive growth behavior.

Example:
  ./inject_memory.sh -k ~/k3s.yaml -s sock-shop -n carts-mem-leaklike \
    -l name=carts -o runs/test1/mem_injection.log \
    --steps "200Mi,400Mi,600Mi" --step-duration 40s

Notes:
  - It overwrites the same StressChaos object each step (kubectl apply).
  - It records epoch timestamps for each step to the output file.
  - Requires Chaos Mesh installed and working on containerd (you already fixed this).
EOF
}

# Defaults
KCFG="~/k3s.yaml"
NAMESPACE="sock-shop"
CHAOS_NAME="mem-leaklike"
LABEL_SELECTOR=""
OUT_PATH="./mem_injection.log"
STEPS="50MB,100MB,150MB,200MB"
STEP_DURATION="15s"
MODE="one"   # one|all|fixed|fixed-percent|random-max-percent
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
    --steps) STEPS="$2"; shift 2 ;;
    --step-duration) STEP_DURATION="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --validate) VALIDATE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

# Require kubeconfig + label selector
if [[ -z "$KCFG" ]]; then
  echo "ERROR: kubeconfig required: -k ~/k3s.yaml" >&2
  exit 4
fi
if [[ ! -f "$KCFG" ]]; then
  echo "ERROR: kubeconfig not found: $KCFG" >&2
  exit 4
fi
if [[ -z "$LABEL_SELECTOR" ]]; then
  echo "ERROR: label selector required: -l key=value (e.g., -l name=carts)" >&2
  exit 4
fi

# Ensure output dir writable
OUT_DIR="$(dirname "$OUT_PATH")"
mkdir -p "$OUT_DIR"
touch "$OUT_PATH" 2>/dev/null || { echo "ERROR: cannot write $OUT_PATH" >&2; exit 10; }

KUBECTL=(kubectl --kubeconfig "$KCFG" -n "$NAMESPACE")

# Split label selector
SEL_KEY="${LABEL_SELECTOR%%=*}"
SEL_VAL="${LABEL_SELECTOR#*=}"
if [[ "$SEL_KEY" == "$SEL_VAL" ]]; then
  echo "ERROR: label selector must be key=value, got: $LABEL_SELECTOR" >&2
  exit 4
fi

# Helper: write logs with local timestamp
ts() { date +"[%Y-%m-%d %H:%M:%S]"; }
epoch() { date +%s; }

# Convert steps CSV -> array
IFS=',' read -r -a STEP_SIZES <<< "$STEPS"

echo "$(ts) Starting memory leak-like injection" | tee -a "$OUT_PATH"
echo "$(ts) namespace=$NAMESPACE name=$CHAOS_NAME selector=$SEL_KEY=$SEL_VAL steps=$STEPS step_duration=$STEP_DURATION workers=$WORKERS" | tee -a "$OUT_PATH"

# Preflight: ensure chaos resource exists
if ! "${KUBECTL[@]}" get crd stresschaos.chaos-mesh.org >/dev/null 2>&1; then
  echo "ERROR: stresschaos.chaos-mesh.org CRD not found. Is Chaos Mesh installed?" | tee -a "$OUT_PATH"
  exit 6
fi

# Apply each step
for i in "${!STEP_SIZES[@]}"; do
  SIZE="${STEP_SIZES[$i]}"
  STEP_NO=$((i+1))
  STEP_NAME="${CHAOS_NAME}-s${STEP_NO}"
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

  echo "$(ts) Step ${STEP_NO}/${#STEP_SIZES[@]} apply name=${STEP_NAME} size=${SIZE} start_epoch=${START_EPOCH}" | tee -a "$OUT_PATH"

  if [[ "$VALIDATE" == "false" ]]; then
    "${KUBECTL[@]}" apply --validate=false -f "$TMP_YAML" >/dev/null
  else
    "${KUBECTL[@]}" apply -f "$TMP_YAML" >/dev/null
  fi

  sleep "$STEP_DURATION"

  # Cleanup this step object (optional but cleaner)
  "${KUBECTL[@]}" delete stresschaos "${STEP_NAME}" --ignore-not-found >/dev/null || true
  rm -f "$TMP_YAML"
done

# Cleanup the chaos object at the end
END_EPOCH="$(epoch)"
echo "$(ts) Deleting StressChaos ${CHAOS_NAME} end_epoch=${END_EPOCH}" | tee -a "$OUT_PATH"
"${KUBECTL[@]}" delete stresschaos "${CHAOS_NAME}" --ignore-not-found >/dev/null || true

echo "$(ts) Done. Log saved to: $OUT_PATH" | tee -a "$OUT_PATH"

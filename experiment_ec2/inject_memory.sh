#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./inject_mem.sh \
    -t <service> \
    -d <duration> \
    -o <epoch_out_file> \
    [-k <kubeconfig>] \
    [-s <namespace>] \
    [-n <chaos_name_prefix>] \
    [-l <label_selector_key=value>] \
    [--log <log_file>] \
    [--start <MB>] [--inc <MB>] [--count <N>] \
    [--step-duration <duration>] \
    [--mode <mode>] [--workers <N>] [--validate]

Required:
  -t <service>        Target service (e.g., carts, orders, users)
  -d <duration>       Total injection duration (e.g., 5m, 120s, 300)
  -o <epoch_out_file> File to write injection start epoch seconds (single number)

Optional:
  -k <kubeconfig>     Default: ~/k3s.yaml
  -s <namespace>      Default: sock-shop
  -n <name_prefix>    Default: <service>-mem-leaklike
  -l <k=v>            Pod label selector. Default: name=<service>
  --log <file>        Log file path. Default: <epoch_out_dir>/mem_injection.log

Memory growth controls:
  --start <MB>        First step size (default: 20MB)
  --inc <MB>          Increment per step (default: 20MB)
  --count <N>         Number of steps (default: auto = floor(duration/step-duration), min 1)
  --step-duration <d> Duration per step (default: 30s)

Chaos Mesh controls:
  --mode <mode>       Default: one
  --workers <N>       Default: 1
  --validate          If set, kubectl apply validates (default: false / uses --validate=false)

Examples:
  # Leak-like: +30MB every 30s for 10 steps (~5 min) on carts
  ./inject_mem.sh -t carts -d 5m -o runs/test1/injection_time.txt -k ~/k3s.yaml \
    --start 30MB --inc 30MB --count 10 --step-duration 30s

  # Same but target orders, selector defaults to name=orders
  ./inject_mem.sh -t orders -d 5m -o runs/test2/injection_time.txt -k ~/k3s.yaml \
    --start 30MB --inc 30MB --step-duration 30s

Notes:
  - This script creates a StressChaos per step (name suffix -s1, -s2, ...) and deletes it after each step.
  - Sizes MUST be in MB like 50MB (not Mi).
EOF
}

# ---------------- defaults ----------------
SERVICE=""
DURATION=""
EPOCH_OUT=""

KCFG="$HOME/k3s.yaml"
NAMESPACE="sock-shop"
CHAOS_NAME=""          # default derived from service
LABEL_SELECTOR=""      # default: name=<service>
LOG_PATH=""            # default derived from epoch_out dir

START_MB="20MB"
INC_MB=""
MAX_MB="130MB"         
COUNT=""               # default: auto from duration/step
STEP_DURATION="30s"

MODE="one"
WORKERS="1"
VALIDATE="false"

# ---------------- helpers ----------------
ts() { date +"[%Y-%m-%d %H:%M:%S]"; }
epoch_now() { date -u +%s; }

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
  echo "Unsupported duration format: $d (use 60s, 2m, 1h, 120)" >&2
  exit 2
}

is_mb() { [[ "$1" =~ ^[0-9]+MB$ ]]; }

# ---------------- arg parsing ----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t) SERVICE="${2:-}"; shift 2 ;;
    -d) DURATION="${2:-}"; shift 2 ;;
    -o) EPOCH_OUT="${2:-}"; shift 2 ;;

    -k) KCFG="${2:-}"; shift 2 ;;
    -s) NAMESPACE="${2:-}"; shift 2 ;;
    -n) CHAOS_NAME="${2:-}"; shift 2 ;;
    -l) LABEL_SELECTOR="${2:-}"; shift 2 ;;
    --log) LOG_PATH="${2:-}"; shift 2 ;;

    --start) START_MB="${2:-}"; shift 2 ;;
    --inc) INC_MB="${2:-}"; shift 2 ;;
    --count) COUNT="${2:-}"; shift 2 ;;
    --step-duration) STEP_DURATION="${2:-}"; shift 2 ;;

    --mode) MODE="${2:-}"; shift 2 ;;
    --workers) WORKERS="${2:-}"; shift 2 ;;
    --validate) VALIDATE="true"; shift 1 ;;

    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# ---------------- validations + derived defaults ----------------
[[ -n "$SERVICE" ]] || { echo "ERROR: -t <service> is required" >&2; usage; exit 4; }
[[ -n "$DURATION" ]] || { echo "ERROR: -d <duration> is required" >&2; usage; exit 4; }
[[ -n "$EPOCH_OUT" ]] || { echo "ERROR: -o <epoch_out_file> is required" >&2; usage; exit 4; }

# Default chaos name / selector
[[ -n "$CHAOS_NAME" ]] || CHAOS_NAME="${SERVICE}-mem-leaklike"
[[ -n "$LABEL_SELECTOR" ]] || LABEL_SELECTOR="name=${SERVICE}"

# kubeconfig
KCFG="${KCFG/#\~/$HOME}"
[[ -f "$KCFG" ]] || { echo "ERROR: kubeconfig not found: $KCFG" >&2; exit 4; }

# label selector parse
SEL_KEY="${LABEL_SELECTOR%%=*}"
SEL_VAL="${LABEL_SELECTOR#*=}"
if [[ -z "$SEL_KEY" || -z "$SEL_VAL" || "$SEL_KEY" == "$SEL_VAL" ]]; then
  echo "ERROR: label selector must be key=value, got: $LABEL_SELECTOR" >&2
  exit 4
fi

# sizes
is_mb "$START_MB" || { echo "ERROR: --start must be like 30MB, got: $START_MB" >&2; exit 4; }
# is_mb "$INC_MB" || { echo "ERROR: --inc must be like 30MB, got: $INC_MB" >&2; exit 4; }

# workers
if ! [[ "$WORKERS" =~ ^[0-9]+$ ]] || [[ "$WORKERS" -lt 1 ]]; then
  echo "ERROR: --workers must be a positive integer, got: $WORKERS" >&2
  exit 4
fi

# auto count if not provided
if [[ -z "${COUNT:-}" ]]; then
  total_s="$(to_seconds "$DURATION")"
  step_s="$(to_seconds "$STEP_DURATION")"
  [[ "$step_s" -gt 0 ]] || { echo "ERROR: bad --step-duration $STEP_DURATION" >&2; exit 4; }
  COUNT=$(( total_s / step_s ))
  [[ "$COUNT" -ge 1 ]] || COUNT=1
fi
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -lt 1 ]]; then
  echo "ERROR: --count must be a positive integer, got: $COUNT" >&2
  exit 4
fi

if [ "$SERVICE" = "carts" ] || [ "$SERVICE" = "orders" ]; then
    MAX_MB="150MB"
fi

start_num="${START_MB%MB}"
max_num="${MAX_MB%MB}"
#inc_num="${INC_MB%MB}"

if [[ "$max_num" -lt "$start_num" ]]; then
  # don't allow exceeding ceiling; treat as constant stress
  max_num="$start_num"
fi

if [[ "$COUNT" -le 1 ]]; then
  inc_num=0
else
  inc_num=$(( (max_num - start_num) / (COUNT - 1) ))
  [[ "$inc_num" -ge 0 ]] || inc_num=0
fi


# output paths
EPOCH_DIR="$(dirname "$EPOCH_OUT")"
mkdir -p "$EPOCH_DIR"
touch "$EPOCH_OUT" 2>/dev/null || { echo "ERROR: cannot write $EPOCH_OUT" >&2; exit 10; }

if [[ -z "$LOG_PATH" ]]; then
  LOG_PATH="${EPOCH_DIR}/mem_injection.log"
fi
LOG_DIR="$(dirname "$LOG_PATH")"
mkdir -p "$LOG_DIR"
touch "$LOG_PATH" 2>/dev/null || { echo "ERROR: cannot write $LOG_PATH" >&2; exit 10; }

KUBECTL=(kubectl --kubeconfig "$KCFG" -n "$NAMESPACE")

# preflight: CRD
if ! "${KUBECTL[@]}" get crd stresschaos.chaos-mesh.org >/dev/null 2>&1; then
  echo "ERROR: stresschaos.chaos-mesh.org CRD not found. Is Chaos Mesh installed?" | tee -a "$LOG_PATH"
  exit 6
fi

# write injection epoch for pipeline
INJECT_EPOCH="$(epoch_now)"
echo -n "$INJECT_EPOCH" > "$EPOCH_OUT"

echo "$(ts) Starting mem injection (leak-like)" | tee -a "$LOG_PATH"
echo "$(ts) service=$SERVICE duration=$DURATION inject_epoch=$INJECT_EPOCH epoch_out=$EPOCH_OUT log=$LOG_PATH" | tee -a "$LOG_PATH"
echo "$(ts) namespace=$NAMESPACE name_prefix=$CHAOS_NAME selector=$SEL_KEY=$SEL_VAL start=$START_MB inc=$INC_MB count=$COUNT step_duration=$STEP_DURATION workers=$WORKERS mode=$MODE" | tee -a "$LOG_PATH"

# ---------------- main loop ----------------
for ((i=1; i<=COUNT; i++)); do
  size_num=$(( start_num + (i-1)*inc_num ))
  if [[ "$size_num" -gt "$max_num" ]]; then size_num="$max_num"; fi
  SIZE="${size_num}MB"
  STEP_NAME="${CHAOS_NAME}-s${i}"

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

  echo "$(ts) Step ${i}/${COUNT}: apply ${STEP_NAME} size=${SIZE}" | tee -a "$LOG_PATH"

  if [[ "$VALIDATE" == "true" ]]; then
    "${KUBECTL[@]}" apply -f "$TMP_YAML" >/dev/null
  else
    "${KUBECTL[@]}" apply --validate=false -f "$TMP_YAML" >/dev/null
  fi

  sleep "$STEP_DURATION"

  "${KUBECTL[@]}" delete stresschaos "${STEP_NAME}" --ignore-not-found >/dev/null || true
  rm -f "$TMP_YAML"
done

echo "$(ts) Done. Log saved to: $LOG_PATH" | tee -a "$LOG_PATH"

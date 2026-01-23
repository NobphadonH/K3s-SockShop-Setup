#!/usr/bin/env bash
set -euo pipefail

# Flow:
#  1) Injection script writes <run>/injection_time.txt
#  2) Export metrics around injection time -> <run>/merged.csv
#  (No detection step)

# ---------------- Defaults (match your old PS1 intent) ----------------
INJECTION_SCRIPT="./inject_stresschaos.sh"                # required
EXPORT_CMD="python3"

EXPORT_SCRIPT="./export_metrics.py"
VENV_PY="$(cd "$(dirname "$0")" && pwd)/.venv_query/bin/python"
EXPORT_CMD="$VENV_PY"

PROM_URL="http://127.0.0.1:8428"
NAMESPACE="sock-shop"
SERVICES_CSV="carts,users,orders,payment,shipping,frontend,catalogue,queue-master,rabbitmq,orders-db,carts-db,users-db"
CONTROLPLANE_RE=".*(control-plane|master).*"
NODE_RATE_WINDOW="3m"
WINDOW_MINUTES=10
STEP="5s"

DURATION=""                        # required
OUT_ROOT="./runs"

SERVICE="carts"

# injection-script passthrough (for our inject_stresschaos.sh)
INJ_YAML="./carts-cpu-stress.yaml"
INJ_NAME="carts-cpu-stress"
INJ_NS="sock-shop"
KUBECONFIG_PATH="/home/ubuntu/k3s.yaml"                 # optional (recommended)

NODES=false                        # optional

usage() {
  cat >&2 <<EOF
Usage: $0 -i <injection_script> -d <duration> -t <service> [options]

Required:
  -i <path>        Injection script (e.g., ./inject_stresschaos.sh)
  -d <duration>    Duration to pass to injector (e.g., 60s, 2m, 1h, 120)
  -t <service>     Target service for injection (e.g., carts, orders, users)

Common options:
  -o <out_root>      Output root folder (default: ./runs)
  -p <prom_url>      Prometheus-compatible query URL 
  -e <export_script> Export script path (default: ./export_metrics.py)
  -c <export_cmd>    Export command (default: python3)

Exporter args:
  -n <namespace>      Namespace (default: sock-shop)
  -s <services_csv>   Services CSV (default: $SERVICES_CSV)
  -w <window_minutes> Window minutes (default: 10)
  --step <step>           Step (default: 5s)
  --nodes             Enable node discovery (passes --nodes to exporter)
  --controlplane-re <regex>  (default: $CONTROLPLANE_RE)

Injector passthrough (for inject_stresschaos.sh):
  --inj-yaml <path>     (default: ./carts-cpu-stress.yaml)
  --inj-name <name>     (default: carts-cpu-stress)
  --inj-ns <namespace>  (default: sock-shop)
  -k <kubeconfig>       Kubeconfig path (passed to injector as -k)

Example:
  $0 -i ./inject_stresschaos.sh -d 60s -k ~/k3s.yaml \\
     -p http://localhost:8428 -e ./export_metrics.py \\
     --inj-yaml ./carts-cpu-stress.yaml --inj-name carts-cpu-stress

EOF
  exit 1
}

# ---------------- helpers (keep same idea as PS1) ----------------
write_log() {
  local msg="$1"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  local line="[$ts] $msg"
  echo "$line"
  echo "$line" >> "$LOG_PATH"
}

read_epoch() {
  local path="$1"
  local name="${2:-epoch}"
  [[ -f "$path" ]] || { echo "ERROR: $name file not found: $path" >&2; exit 2; }
  local raw
  raw="$(head -n 1 "$path" | tr -d ' \t\r\n')"
  [[ "$raw" =~ ^[0-9]{10}$ ]] || { echo "ERROR: $name in $path is not a 10-digit epoch seconds value. Got: '$raw'" >&2; exit 3; }
  echo "$raw"
}

# ---------------- arg parsing ----------------
# We support a couple of long options manually.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) INJECTION_SCRIPT="${2:-}"; shift 2 ;;
    -d) DURATION="${2:-}"; shift 2 ;;
    -t) SERVICE="${2:-}"; shift 2 ;;
    -o) OUT_ROOT="${2:-}"; shift 2 ;;
    -p) PROM_URL="${2:-}"; shift 2 ;;
    -e) EXPORT_SCRIPT="${2:-}"; shift 2 ;;
    -c) EXPORT_CMD="${2:-}"; shift 2 ;;
    -n) NAMESPACE="${2:-}"; shift 2 ;;
    -s) SERVICES_CSV="${2:-}"; shift 2 ;;
    -w) WINDOW_MINUTES="${2:-}"; shift 2 ;;
    --step) STEP="${2:-}"; shift 2 ;;
    -k) KUBECONFIG_PATH="${2:-}"; shift 2 ;;
    --nodes) NODES=true; shift 1 ;;
    --controlplane-re) CONTROLPLANE_RE="${2:-}"; shift 2 ;;
    --inj-yaml) INJ_YAML="${2:-}"; shift 2 ;;
    --inj-name) INJ_NAME="${2:-}"; shift 2 ;;
    --inj-ns) INJ_NS="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$INJECTION_SCRIPT" ]] || usage
[[ -n "$DURATION" ]] || usage
[[ -n "$SERVICE" ]] || usage

# ---------------- prep run folder (same behavior as PS1) ----------------
TS_NAME="$(date '+%Y%m%d_%H%M%S')"
RUN_DIR="${OUT_ROOT}/${TS_NAME}"
mkdir -p "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"

LOG_PATH="${RUN_DIR}/pipeline.log"
echo "RCA pipeline log" > "$LOG_PATH"

INJECT_TIME_FILE="${RUN_DIR}/injection_time.txt"
DURATION_FILE="${RUN_DIR}/injection_duration.txt"
MERGED_CSV="${RUN_DIR}/merged.csv"

write_log "Run directory: $RUN_DIR"

# ===================== 1) INJECTION =====================
write_log "STEP 1: injection script writes start epoch to $INJECT_TIME_FILE"
write_log "Duration requested: $DURATION"
echo -n "$DURATION" > "$DURATION_FILE"

# Build injector command
INJ_CMD=( "$INJECTION_SCRIPT"
  -d "$DURATION"
  -o "$INJECT_TIME_FILE"
  -n "$INJ_NAME"
  -s "$INJ_NS"
  -t "$SERVICE"
)

# Only pass -k if provided (keeps it flexible)
if [[ -n "$KUBECONFIG_PATH" ]]; then
  INJ_CMD+=( -k "$KUBECONFIG_PATH" )
fi

write_log "Calling injector: ${INJ_CMD[*]}"
# tee stdout+stderr into log while still failing on errors
( "${INJ_CMD[@]}" ) 2>&1 | tee -a "$LOG_PATH"

write_log "Injection script finished."

INJECT_EPOCH="$(read_epoch "$INJECT_TIME_FILE" "injection_time")"
write_log "Injection epoch (start): $INJECT_EPOCH"

# ===================== 2) EXPORT =====================
write_log "STEP 2: export metrics around injection time -> $MERGED_CSV"

EXP_ARGS=(
  "--prom" "$PROM_URL"
  "--services" "$SERVICES_CSV"
  "--namespace" "$NAMESPACE"
  "--inject" "$INJECT_EPOCH"
  "--window-minutes" "$WINDOW_MINUTES"
  "--step" "$STEP"
  "--out" "$MERGED_CSV"
  "--controlplane-re" "$CONTROLPLANE_RE"
  # "--node-rate-window" "$NODE_RATE_WINDOW"
)

if $NODES; then
  EXP_ARGS+=( "--nodes" )
fi

write_log "Calling: $EXPORT_CMD $EXPORT_SCRIPT ${EXP_ARGS[*]}"
( "$EXPORT_CMD" "$EXPORT_SCRIPT" "${EXP_ARGS[@]}" ) 2>&1 | tee -a "$LOG_PATH"

if [[ ! -f "$MERGED_CSV" ]]; then
  echo "ERROR: Export failed: CSV not found at $MERGED_CSV" >&2
  exit 4
fi

write_log "Export OK."

write_log "DONE. Artifacts:"
write_log "  - $INJECT_TIME_FILE"
write_log "  - $DURATION_FILE"
write_log "  - $MERGED_CSV"

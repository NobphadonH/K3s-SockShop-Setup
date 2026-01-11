#!/usr/bin/env bash
set -euo pipefail

# Network delay injection using Chaos Mesh (NetworkChaos)
# Compatible flags with your pipeline:
#   -d <duration>  -o <out_file>  -y <yaml_path>  -n <chaos_name>  -s <namespace>  -k <kubeconfig>

DURATION=""
OUT_FILE=""
YAML_PATH=""
CHAOS_NAME="carts-net-delay"
CHAOS_NS="sock-shop"
KUBECONFIG_PATH=""

# Defaults for network delay
TARGET_NAMESPACE="sock-shop"
TARGET_LABEL_KEY="app"
TARGET_LABEL_VAL="carts"

LATENCY="200ms"
JITTER="50ms"
CORRELATION="25"   # percent (string)

DIRECTION="to"     # to | from | both
MODE="all"         # all | one | fixed | fixed-percent | random-max-percent
VALUE=""           # required for some modes (e.g., fixed=1)
VALIDATE="false"

# ---- helpers ----
usage() {
  cat >&2 <<EOF
Usage: $0 -d <duration> -o <out_file> [-y <yaml_path>] [-n <chaos_name>] [-s <chaos_namespace>] [-k <kubeconfig>]
          [--target-ns <ns>] [--label <k=v>]
          [--latency <e.g. 200ms>] [--jitter <e.g. 50ms>] [--correlation <0-100>]
          [--direction to|from|both]
          [--mode all|one|fixed|fixed-percent|random-max-percent] [--value <num>]

Notes:
- If -y points to an existing file, we apply that YAML directly (we'll still delete by name in -s/-n).
- If -y is empty or file doesn't exist, we generate a NetworkChaos YAML automatically.

Examples:
  $0 -d 60s -o ./injection_time.txt -n carts-net-delay -s sock-shop -k ~/k3s.yaml \\
     --label app=carts --latency 250ms --jitter 50ms --correlation 25 --direction to

EOF
  exit 1
}

# Convert duration like 60s / 2m / 1h / 120 (seconds) -> seconds
duration_to_seconds() {
  local d="$1"
  d="$(echo "$d" | tr -d '[:space:]')"
  if [[ "$d" =~ ^[0-9]+$ ]]; then
    echo "$d"
    return
  fi
  if [[ "$d" =~ ^([0-9]+)(s|m|h)$ ]]; then
    local num="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"
    case "$unit" in
      s) echo "$num" ;;
      m) echo $(( num * 60 )) ;;
      h) echo $(( num * 3600 )) ;;
    esac
    return
  fi
  echo "ERROR: invalid duration format: '$d' (use 60s, 2m, 1h, or plain seconds like 120)" >&2
  exit 2
}

kube_args=()
maybe_set_kubeconfig() {
  if [[ -n "$KUBECONFIG_PATH" ]]; then
    # Expand ~ if present
    local kc="$KUBECONFIG_PATH"
    if [[ "$kc" == ~* ]]; then
      kc="${kc/#\~/$HOME}"
    fi
    kube_args+=( --kubeconfig "$kc" )
  fi
}

# ---- arg parsing ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) DURATION="${2:-}"; shift 2 ;;
    -o) OUT_FILE="${2:-}"; shift 2 ;;
    -y) YAML_PATH="${2:-}"; shift 2 ;;
    -n) CHAOS_NAME="${2:-}"; shift 2 ;;
    -s) CHAOS_NS="${2:-}"; shift 2 ;;
    -k) KUBECONFIG_PATH="${2:-}"; shift 2 ;;

    --target-ns) TARGET_NAMESPACE="${2:-}"; shift 2 ;;
    --label)
      # expects k=v
      kv="${2:-}"
      shift 2
      [[ "$kv" == *"="* ]] || { echo "ERROR: --label expects k=v" >&2; exit 2; }
      TARGET_LABEL_KEY="${kv%%=*}"
      TARGET_LABEL_VAL="${kv#*=}"
      ;;
    --latency) LATENCY="${2:-}"; shift 2 ;;
    --jitter) JITTER="${2:-}"; shift 2 ;;
    --correlation) CORRELATION="${2:-}"; shift 2 ;;
    --direction) DIRECTION="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --value) VALUE="${2:-}"; shift 2 ;;

    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

[[ -n "$DURATION" ]] || usage
[[ -n "$OUT_FILE" ]] || usage

maybe_set_kubeconfig

DUR_SECS="$(duration_to_seconds "$DURATION")"

# ---- prepare yaml ----
TMP_YAML=""
YAML_TO_APPLY=""

if [[ -n "${YAML_PATH:-}" && -f "$YAML_PATH" ]]; then
  YAML_TO_APPLY="$YAML_PATH"
else
  TMP_YAML="$(mktemp -t networkchaos-delay-XXXXXX.yaml)"
  YAML_TO_APPLY="$TMP_YAML"

  # Validate MODE/VALUE
  case "$MODE" in
    all|one) ;;
    fixed|fixed-percent|random-max-percent)
      [[ -n "$VALUE" ]] || { echo "ERROR: --mode $MODE requires --value" >&2; exit 2; }
      ;;
    *)
      echo "ERROR: invalid --mode '$MODE'" >&2
      exit 2
      ;;
  esac

  cat > "$YAML_TO_APPLY" <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: ${CHAOS_NAME}
  namespace: ${CHAOS_NS}
spec:
  action: delay
  mode: ${MODE}
EOF

  if [[ "$MODE" =~ ^(fixed|fixed-percent|random-max-percent)$ ]]; then
    cat >> "$YAML_TO_APPLY" <<EOF
  value: "${VALUE}"
EOF
  fi

  cat >> "$YAML_TO_APPLY" <<EOF
  selector:
    namespaces:
      - ${TARGET_NAMESPACE}
    labelSelectors:
      "${TARGET_LABEL_KEY}": "${TARGET_LABEL_VAL}"
  delay:
    latency: "${LATENCY}"
    jitter: "${JITTER}"
    correlation: "${CORRELATION}"
  direction: "${DIRECTION}"
EOF
fi

# ---- apply chaos ----
echo "[inject_network_delay] Applying NetworkChaos '${CHAOS_NAME}' in ns '${CHAOS_NS}'"

if [[ "$VALIDATE" == "false" ]]; then
    kubectl "${kube_args[@]}" apply --validate=false -f "$YAML_TO_APPLY" >/dev/null
else
    kubectl "${kube_args[@]}" apply -f "$YAML_TO_APPLY" >/dev/null
fi


# Write start epoch seconds (10-digit)
START_EPOCH="$(date +%s)"
echo -n "$START_EPOCH" > "$OUT_FILE"
echo "[inject_network_delay] Wrote injection start epoch to: $OUT_FILE -> $START_EPOCH"

echo "[inject_network_delay] Sleeping for ${DUR_SECS}s (duration=${DURATION})"
sleep "$DUR_SECS"

# ---- cleanup ----
echo "[inject_network_delay] Deleting NetworkChaos '${CHAOS_NAME}' in ns '${CHAOS_NS}'"
kubectl "${kube_args[@]}" -n "$CHAOS_NS" delete networkchaos "$CHAOS_NAME" --ignore-not-found >/dev/null

echo "[inject_network_delay] Done."

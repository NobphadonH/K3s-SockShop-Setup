#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./inject_stresschaos.sh -d 60s -y ./carts-cpu-stress.yaml -o ./injection_time.txt
#
# Optional:
#   -n name        (default: carts-cpu-stress)
#   -s namespace   (default: sock-shop)
#   -k kubeconfig  (default: uses $KUBECONFIG if set, otherwise ~/.kube/config)

DURATION=""
YAML_PATH="./carts-cpu-stress.yaml"
NAME="carts-cpu-stress"
NAMESPACE="sock-shop"
OUT_PATH=""
KCFG="~/k3s.yaml"

usage() {
  echo "Usage: $0 -d <duration> -o <out_path> [-y <yaml_path>] [-n <name>] [-s <namespace>] [-k <kubeconfig>]" >&2
  echo "  duration formats: 60s | 2m | 1h | 120 (seconds)" >&2
  exit 1
}

to_seconds() {
  local d="$1"
  if [[ "$d" =~ ^[0-9]+$ ]]; then
    echo "$d"
    return
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

while getopts ":d:y:n:s:o:k:" opt; do
  case "$opt" in
    d) DURATION="$OPTARG" ;;
    y) YAML_PATH="$OPTARG" ;;
    n) NAME="$OPTARG" ;;
    s) NAMESPACE="$OPTARG" ;;
    o) OUT_PATH="$OPTARG" ;;
    k) KCFG="$OPTARG" ;;
    *) usage ;;
  esac
done

[[ -n "$DURATION" ]] || usage
[[ -n "$OUT_PATH" ]] || usage
[[ -f "$YAML_PATH" ]] || { echo "YAML not found: $YAML_PATH" >&2; exit 3; }

KUBECTL=(kubectl)
if [[ -n "$KCFG" ]]; then
  [[ -f "$KCFG" ]] || { echo "Kubeconfig not found: $KCFG" >&2; exit 4; }
  KUBECTL+=(--kubeconfig "$KCFG")
fi

# 1) Clean any previous StressChaos run
"${KUBECTL[@]}" delete stresschaos "$NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true

# 2) Apply your YAML file as-is
"${KUBECTL[@]}" apply -f "$YAML_PATH" >/dev/null

# 3) Record injection start time (Unix timestamp, UTC-based)
EPOCH="$(date -u +%s)"

# 4) Save to injection_time.txt (single number only)
echo -n "$EPOCH" > "$OUT_PATH"

echo "[$(date +%H:%M:%S)] StressChaos $NAME applied. Injection time (epoch): $EPOCH"

# 5) Wait for the specified duration
SECONDS_TO_SLEEP="$(to_seconds "$DURATION")"
sleep "$SECONDS_TO_SLEEP"

# 6) Delete StressChaos to clean up
"${KUBECTL[@]}" delete stresschaos "$NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
echo "[$(date +%H:%M:%S)] StressChaos $NAME deleted after $DURATION."

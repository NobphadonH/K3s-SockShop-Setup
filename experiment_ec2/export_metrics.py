#!/usr/bin/env python3
"""
Export Sock Shop service + node metrics into a single, wide CSV for RCA.

(UNCHANGED CLI / behavior)
- Pulls container CPU/Mem/Net (cAdvisor/Kubelet)
- Pulls Istio request/error and latency percentiles (from histograms)
- Pulls a small, curated set of node metrics (help causal structure; not eval labels)
- Aligns all series on a common wall-clock index and writes to CSV.

ADJUSTED IN THIS VERSION (per our agreement):
- Container CPU/Mem selectors use container!="POD" (not image!="")
- Memory uses container_memory_working_set_bytes
- Istio HTTP workload/error/latency keyed by destination_service_name (+ namespace)
- queue-master has no HTTP metrics in your setup:
    * workload uses istio_tcp_sent_bytes_total (bytes/sec)
    * latency-50/90 left as NaN (not derivable from standard Istio TCP telemetry)
"""

import argparse
import datetime as dt
import math
import sys
from typing import Dict, Optional

import pandas as pd
import requests

rate_window = "3m"

def _parse_args():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prom", default="http://127.0.0.1:8428",
                    help="Prometheus base URL, e.g. http://localhost:9090")
    ap.add_argument(
        "--services",
        default="carts,user,orders,payment,shipping,front-end,catalogue,queue-master,rabbitmq,orders-db,carts-db,user-db",
        help="Comma-separated list of service workload names (used for pod regex + Istio service label)",
    )
    ap.add_argument("--nodes", action="store_true",
                    help="Auto-discover all worker nodes (exclude control-plane)")
    ap.add_argument("--controlplane-re", default=".*(control-plane|master).*",
                    help="Regex for control-plane nodename(s) in node_uname_info")
    ap.add_argument("--namespace", default="sock-shop",
                    help="K8s namespace for container selectors")
    ap.add_argument("--start", help="RFC3339 start (e.g. 2025-11-09T12:30:00Z)")
    ap.add_argument("--end", help="RFC3339 end (e.g. 2025-11-09T13:30:00Z)")
    ap.add_argument("--step", default="15s",
                    help="Query step (e.g. 5s, 15s, 1m)")
    ap.add_argument("--inject", type=int,
                    help="Injection epoch seconds (optional shortcut to set start/end)")
    ap.add_argument("--window-minutes", type=int, default=10,
                    help="Window minutes on each side of --inject")
    ap.add_argument("--out", default="merged_v4.csv",
                    help="Output CSV path")
    ap.add_argument("--timeout", type=int, default=120,
                    help="HTTP timeout seconds")
    ap.add_argument("--verify-tls", action="store_true",
                    help="Verify TLS certs to Prometheus")
    ap.add_argument("--lat-histogram", choices=["ms", "s"], default="ms",
                    help="Istio duration unit in histogram name: 'ms' or 's'")
    ap.add_argument("--bytes-histogram", choices=["response", "request"], default="response",
                    help="Unused here (kept for compatibility)")
    return ap.parse_args()

def prom_instant(prom: str, q: str, timeout: int, verify: bool) -> dict:
    url = f"{prom.rstrip('/')}/api/v1/query"
    params = {"query": q}
    r = requests.get(url, params=params, timeout=timeout, verify=verify)
    data = r.json()
    if r.status_code != 200 or data.get("status") != "success":
        err = data.get("error") or data
        raise RuntimeError(f"Prometheus instant error:\nQuery:\n{q}\n\nError:\n{err}")
    return data

def discover_worker_instances(prom: str, timeout: int, verify: bool, controlplane_re: str) -> list[str]:
    q = f'sum by (instance, nodename) (node_uname_info{{nodename!~"{controlplane_re}"}})'
    try:
        data = prom_instant(prom, q, timeout, verify)
        res = data["data"]["result"]
        if res:
            return [s["metric"]["instance"] for s in res if "instance" in s["metric"]]
    except Exception:
        pass

    data = prom_instant(prom, 'sum by (instance) (rate(node_cpu_seconds_total[2m]))', timeout, verify)
    res = data["data"]["result"]
    return [s["metric"]["instance"] for s in res if "instance" in s["metric"]]

def _rfc3339_from_epoch(e: int) -> str:
    return dt.datetime.fromtimestamp(e, tz=dt.timezone.utc).isoformat().replace("+00:00", "Z")

def _compute_window(args):
    if args.inject and (not args.start and not args.end):
        half = args.window_minutes * 60
        start_epoch = args.inject - half
        end_epoch = args.inject + half
        return _rfc3339_from_epoch(start_epoch), _rfc3339_from_epoch(end_epoch)
    if not args.start or not args.end:
        raise SystemExit("--start/--end or --inject must be provided")
    return args.start, args.end

def prom_range(prom: str, q: str, start: str, end: str, step: str, timeout: int, verify: bool) -> Dict:
    url = f"{prom.rstrip('/')}/api/v1/query_range"
    params = {"query": q, "start": start, "end": end, "step": step}
    r = requests.get(url, params=params, timeout=timeout, verify=verify)
    r.raise_for_status()
    data = r.json()
    if data.get("status") != "success":
        raise RuntimeError(f"Prometheus error for {q}: {data}")
    return data

def _ts_matrix_to_series(payload: Dict, target_col: str) -> pd.DataFrame:
    res = payload["data"]["result"]
    if not res:
        return pd.DataFrame(columns=["time", target_col]).set_index("time")

    frames = []
    for series in res:
        vals = series.get("values") or []
        if not vals:
            continue

        # Keep time as epoch seconds INT (no datetime conversion)
        ts = [int(float(t)) for t, _ in vals]
        v = []
        for _, x in vals:
            # be robust to weird strings
            if x in ("NaN", "Inf", "-Inf", None):
                v.append(math.nan)
            else:
                try:
                    v.append(float(x))
                except Exception:
                    v.append(math.nan)

        frames.append(pd.DataFrame({"time": ts, target_col: v}).set_index("time"))

    if not frames:
        return pd.DataFrame(columns=["time", target_col]).set_index("time")

    # Sum across returned series (pods) at the SAME epoch second
    df = pd.concat(frames, axis=0).groupby(level=0).sum(min_count=1)
    df.index.name = "time"
    return df

def _merge_into(base: Optional[pd.DataFrame], newdf: pd.DataFrame) -> pd.DataFrame:
    if base is None:
        return newdf
    return base.join(newdf, how="outer")

# -----------------------------
# PromQL builders (adjusted)
# -----------------------------

def q_container_cpu_usage(namespace: str, svc: str) -> str:
    # Use container filters instead of image!=""
    return f'''
sum by (pod) (
  rate(container_cpu_usage_seconds_total{{namespace="{namespace}", pod=~"{svc}.*", container!="POD", container!=""}}[{rate_window}])
)
'''.strip()

def q_mem_usage(namespace: str, svc: str) -> str:
    # Working set is a better “real memory pressure” signal
    return f'''
max by (pod) (
  container_memory_working_set_bytes{{namespace="{namespace}", pod=~"{svc}.*", container!="POD", container!=""}}
)
'''.strip()

def _istio_latency_quantile_service(namespace: str, svc: str, qtile: float, unit: str) -> str:
    metric = "istio_request_duration_milliseconds_bucket" if unit == "ms" else "istio_request_duration_seconds_bucket"
    # destination_service_name label (as per your VM)
    return f'''
histogram_quantile({qtile},
  sum by (le) (
    rate({metric}{{reporter="source", destination_service_name="{svc}", destination_service_namespace="{namespace}"}}[{rate_window}])
  )
)
'''.strip()

def q_istio_requests_service(namespace: str, svc: str) -> str:
    return f'''
sum (
  rate(istio_requests_total{{reporter="source", destination_service_name="{svc}", destination_service_namespace="{namespace}"}}[{rate_window}])
)
'''.strip()

def q_istio_errors_service(namespace: str, svc: str) -> str:
    return f'''
sum (
  rate(istio_requests_total{{reporter="source", destination_service_name="{svc}", destination_service_namespace="{namespace}", response_code=~"5.."}}[{rate_window}])
)
'''.strip()

def q_queue_master_tcp_workload(namespace: str) -> str:
    # bytes/sec from queue-master (TCP/AMQP traffic), since HTTP metrics are empty
    return f'''
sum(
  rate(istio_tcp_sent_bytes_total{{reporter="source", source_workload="queue-master", source_workload_namespace="{namespace}"}}[{rate_window}])
)
'''.strip()

# --- Node metrics (left intact; omitted from final CSV schema output) ---

def q_node_cpu_usage(instance: str, rate_window: str) -> str:
    return f'''
sum by (instance) (
  rate(node_cpu_seconds_total{{mode!="idle", instance="{instance}"}}[{rate_window}])
)
/
sum by (instance) (
  rate(node_cpu_seconds_total{{instance="{instance}"}}[{rate_window}])
)
'''.strip()

def q_node_mem_available(instance: str) -> str:
    return f'node_memory_MemAvailable_bytes{{instance="{instance}"}}'

def q_node_net_rx_err(instance: str, rate_window: str) -> str:
    return f'sum by (instance) (rate(node_network_receive_errs_total{{instance="{instance}", device!="lo"}}[{rate_window}]))'

def q_node_net_tx_err(instance: str, rate_window: str) -> str:
    return f'sum by (instance) (rate(node_network_transmit_errs_total{{instance="{instance}", device!="lo"}}[{rate_window}]))'

def collect_for_node(prom, instance, start, end, step, timeout, verify, rate_window) -> pd.DataFrame:
    df_all = None

    col = f"node_{instance}_cpu-usage"
    payload = prom_range(prom, q_node_cpu_usage(instance, rate_window), start, end, step, timeout, verify)
    df_all = _merge_into(df_all, _ts_matrix_to_series(payload, col))

    col = f"node_{instance}_mem-available-bytes"
    payload = prom_range(prom, q_node_mem_available(instance), start, end, step, timeout, verify)
    df_all = _merge_into(df_all, _ts_matrix_to_series(payload, col))

    col = f"node_{instance}_net-rx-errors"
    payload = prom_range(prom, q_node_net_rx_err(instance, rate_window), start, end, step, timeout, verify)
    df_all = _merge_into(df_all, _ts_matrix_to_series(payload, col))

    col = f"node_{instance}_net-tx-errors"
    payload = prom_range(prom, q_node_net_tx_err(instance, rate_window), start, end, step, timeout, verify)
    df_all = _merge_into(df_all, _ts_matrix_to_series(payload, col))

    return df_all

# -----------------------------
# SIMPLE schema (exact order)
# -----------------------------

SIMPLE_COLS_ORDER = [
    "time",
    # cpu (15)
    "carts_cpu","carts-db_cpu","catalogue_cpu","catalogue-db_cpu","front-end_cpu",
    "orders_cpu","orders-db_cpu","payment_cpu","queue-master_cpu","rabbitmq_cpu",
    "session-db_cpu","shipping_cpu","user_cpu","user-db_cpu",
    # mem (15)
    "carts_mem","carts-db_mem","catalogue_mem","catalogue-db_mem","front-end_mem",
    "orders_mem","orders-db_mem","payment_mem","queue-master_mem","rabbitmq_mem",
    "session-db_mem","shipping_mem","user_mem","user-db_mem",
    # workload (8)
    "carts_workload","catalogue_workload","front-end_workload","orders_workload",
    "payment_workload","queue-master_workload","shipping_workload","user_workload",
    # error (5)
    "carts_error","front-end_error","orders_error","queue-master_error","shipping_error",
    # latency-50 (8)
    "carts_latency-50","catalogue_latency-50","front-end_latency-50","orders_latency-50",
    "payment_latency-50","shipping_latency-50","user_latency-50",
    # latency-90 (8)
    "carts_latency-90","catalogue_latency-90","front-end_latency-90","orders_latency-90",
    "payment_latency-90","shipping_latency-90","user_latency-90",
]

WORKLOAD_SERVICES = {"carts","catalogue","front-end","orders","payment","queue-master","shipping","user"}
ERROR_SERVICES    = {"carts","front-end","orders","queue-master","shipping"}
LAT_SERVICES      = {"carts","catalogue","front-end","orders","payment","shipping","user"}

def collect_for_service_simple(prom, ns, svc, start, end, step, timeout, verify, lat_unit) -> pd.DataFrame:
    df_all = None

    # CPU
    cpu_col = f"{svc}_cpu"
    payload = prom_range(prom, q_container_cpu_usage(ns, svc), start, end, step, timeout, verify)
    df_all = _merge_into(df_all, _ts_matrix_to_series(payload, cpu_col))

    # MEM
    mem_col = f"{svc}_mem"
    payload = prom_range(prom, q_mem_usage(ns, svc), start, end, step, timeout, verify)
    print(svc, "mem payload series=", len(payload["data"]["result"]),"last payload ts=", int(float(payload["data"]["result"][0]["values"][-1][0])))
    df_all = _merge_into(df_all, _ts_matrix_to_series(payload, mem_col))

    # WORKLOAD
    if svc in WORKLOAD_SERVICES:
        w_col = f"{svc}_workload"
        if svc == "queue-master":
            # TCP workload (bytes/sec) in your setup
            payload = prom_range(prom, q_queue_master_tcp_workload(ns), start, end, step, timeout, verify)
            df_all = _merge_into(df_all, _ts_matrix_to_series(payload, w_col))
        else:
            payload = prom_range(prom, q_istio_requests_service(ns, svc), start, end, step, timeout, verify)
            df_all = _merge_into(df_all, _ts_matrix_to_series(payload, w_col))

    # ERROR
    if svc in ERROR_SERVICES:
        e_col = f"{svc}_error"
        if svc == "queue-master":
            # No HTTP errors expected for queue-master (TCP traffic). Keep column as NaN (schema will include it).
            pass
        else:
            payload = prom_range(prom, q_istio_errors_service(ns, svc), start, end, step, timeout, verify)
            df_all = _merge_into(df_all, _ts_matrix_to_series(payload, e_col))

    # LATENCY
    if svc in LAT_SERVICES:
        if svc == "queue-master":
            # Not derivable from standard Istio TCP telemetry; leave as NaN.
            pass
        else:
            for qtile, suffix in [(0.50, "latency-50"), (0.90, "latency-90")]:
                l_col = f"{svc}_{suffix}"
                q = _istio_latency_quantile_service(ns, svc, qtile, lat_unit)
                payload = prom_range(prom, q, start, end, step, timeout, verify)
                df_all = _merge_into(df_all, _ts_matrix_to_series(payload, l_col))

    return df_all

def main():
    args = _parse_args()
    start, end = _compute_window(args)
    services = [s.strip() for s in args.services.split(",") if s.strip()]

    merged: Optional[pd.DataFrame] = None

    # Services (simple output)
    for svc in services:
        svc_df = collect_for_service_simple(
            args.prom, args.namespace, svc, start, end, args.step,
            args.timeout, args.verify_tls, args.lat_histogram
        )
        if svc_df is not None:
            merged = _merge_into(merged, svc_df)

    # Nodes (optional) - still collected to keep functionality, but omitted from final CSV
    if args.nodes:
        worker_instances = discover_worker_instances(
            args.prom, args.timeout, args.verify_tls, args.controlplane_re
        )
        if not worker_instances:
            print("Warning: no worker instances discovered (check node_exporter/node_uname_info).", file=sys.stderr)
        else:
            for inst in worker_instances:
                node_df = collect_for_node(
                    args.prom, inst, start, end, args.step, args.timeout, args.verify_tls, rate_window
                )
                if node_df is not None:
                    merged = _merge_into(merged, node_df)

    if merged is None or merged.empty:
        print("No data returned. Check labels, metric names, or time range.", file=sys.stderr)
        sys.exit(2)


    for svc in ERROR_SERVICES:
        col = f"{svc}_error"
        if col in merged.columns:
            merged[col] = merged[col].fillna(0.0)

    # Convert time index to epoch seconds
    #merged.index = merged.index.astype("int64") // 10**9
    #merged.index.name = "time"

    # Force output schema to match simple_data.csv exactly
    out_df = merged.copy()
    for col in SIMPLE_COLS_ORDER:
        if col == "time":
            continue
        if col not in out_df.columns:
            out_df[col] = math.nan

    out_df = out_df.reset_index()
    out_df = out_df[SIMPLE_COLS_ORDER]
    out_df.to_csv(args.out, index=False)
    print(f"Wrote {args.out} with shape {out_df.shape}")

if __name__ == "__main__":
    main()

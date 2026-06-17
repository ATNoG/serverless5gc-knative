#!/usr/bin/env python3
"""Parse Serverless5GC SAF queue-proxy logs and generate seaborn PDF graphs."""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
import sys
from pathlib import Path

import pandas as pd

COMPARISON = 6.5
SIZE = (10, 3.5)
STEP_SIZE = (12, 6.5)
SIZE_RATION = SIZE[0] / COMPARISON
STEP_SIZE_RATION = STEP_SIZE[0] / COMPARISON
LAT_RE = re.compile(r'"latency":\s*"([0-9.]+)s"')

SERVICE_TO_STEP = {
    "smf-pdu-session-create": "smf_pdu_create",
    "pcf-policy-create": "pcf_policy_create",
    "nsacf-slice-availability-check": "nsacf_slice_check",
    "bsf-binding-register": "bsf_binding_register",
    "chf-charging-create": "chf_charging_create",
    "nsacf-update-counters": "nsacf_update_counters",
}
STEP_ORDER = list(SERVICE_TO_STEP.values())


def read_metadata(results_dir: Path) -> dict:
    metadata_path = results_dir / "metadata.json"
    if not metadata_path.exists():
        return {}
    return json.loads(metadata_path.read_text(encoding="utf-8"))


def extract_latencies(path: Path) -> list[float]:
    latencies = []
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = LAT_RE.search(line)
            if match:
                latencies.append(float(match.group(1)) * 1000.0)
    return latencies


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = (len(ordered) - 1) * pct
    low = int(index)
    high = min(low + 1, len(ordered) - 1)
    fraction = index - low
    return ordered[low] + (ordered[high] - ordered[low]) * fraction


def mode_dirs(results_dir: Path) -> list[Path]:
    return sorted(path for path in results_dir.iterdir() if path.is_dir() and (path / "logs").exists())


def parse_logs(results_dir: Path, warmup: int, iterations: int | None) -> pd.DataFrame:
    records = []
    warnings = []
    for mode_dir in mode_dirs(results_dir):
        mode = mode_dir.name
        for service, step in SERVICE_TO_STEP.items():
            service_dir = mode_dir / "logs" / service
            latencies = []
            for log_file in sorted(service_dir.glob("*_queue_proxy_logs.txt")):
                latencies.extend(extract_latencies(log_file))

            if warmup:
                latencies = latencies[warmup:]
            if iterations is not None:
                if len(latencies) < iterations:
                    warnings.append(f"{mode}/{service}: found {len(latencies)} measured queue-proxy latencies, expected {iterations}")
                latencies = latencies[:iterations]

            for sample_id, latency_ms in enumerate(latencies, start=1):
                records.append(
                    {
                        "mode": mode,
                        "record_type": "step",
                        "sample_id": sample_id,
                        "service": service,
                        "step": step,
                        "duration_ms": latency_ms,
                    }
                )

    for warning in warnings:
        print(f"WARNING: {warning}", file=sys.stderr)
    return pd.DataFrame.from_records(records)


def add_flow_totals(raw: pd.DataFrame) -> pd.DataFrame:
    if raw.empty:
        return raw
    totals = (
        raw.groupby(["mode", "sample_id"], as_index=False)
        .agg(duration_ms=("duration_ms", "sum"), steps=("step", "nunique"))
    )
    totals = totals[totals["steps"] == len(STEP_ORDER)].copy()
    totals["record_type"] = "flow"
    totals["service"] = "representative-flow"
    totals["step"] = "flow_total"
    totals = totals[["mode", "record_type", "sample_id", "service", "step", "duration_ms"]]
    return pd.concat([raw, totals], ignore_index=True)


def write_tables(results_dir: Path, raw: pd.DataFrame) -> None:
    raw_path = results_dir / "queue-proxy-latency-raw.csv"
    raw.to_csv(raw_path, index=False)

    summary_rows = []
    for (mode, record_type, step), group in raw.groupby(["mode", "record_type", "step"], sort=False):
        values = group["duration_ms"].astype(float).tolist()
        stderr = statistics.stdev(values) / math.sqrt(len(values)) if len(values) > 1 else 0.0
        summary_rows.append(
            {
                "mode": mode,
                "record_type": record_type,
                "step": step,
                "count": len(values),
                "mean_ms": statistics.fmean(values),
                "stderr_ms": stderr,
                "median_ms": statistics.median(values),
                "p95_ms": percentile(values, 0.95),
                "min_ms": min(values),
                "max_ms": max(values),
            }
        )
    summary_path = results_dir / "queue-proxy-latency-summary.csv"
    with summary_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(summary_rows[0].keys()) if summary_rows else ["mode"])
        writer.writeheader()
        writer.writerows(summary_rows)

    baseline = raw[raw["mode"] == "baseline"]
    saf = raw[raw["mode"] == "saf"]
    diff_path = results_dir / "queue-proxy-latency-difference.csv"
    if not baseline.empty and not saf.empty:
        paired = saf.merge(
            baseline,
            on=["record_type", "step", "sample_id"],
            suffixes=("_saf", "_baseline"),
            how="inner",
        )
        paired["difference_ms"] = paired["duration_ms_saf"] - paired["duration_ms_baseline"]
        paired[["record_type", "step", "sample_id", "difference_ms"]].to_csv(diff_path, index=False)
    else:
        pd.DataFrame(columns=["record_type", "step", "sample_id", "difference_ms"]).to_csv(diff_path, index=False)

    print(f"Wrote {raw_path}")
    print(f"Wrote {summary_path}")
    print(f"Wrote {diff_path}")


def write_charts(results_dir: Path, raw: pd.DataFrame) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import seaborn as sns

    charts_dir = results_dir / "charts"
    charts_dir.mkdir(exist_ok=True)
    (charts_dir / "saf_overhead_by_step.pdf").unlink(missing_ok=True)
    sns.set(style="whitegrid")

    order = [step for step in STEP_ORDER if step in set(raw["step"])]
    if "flow_total" in set(raw["step"]):
        order.append("flow_total")

    plt.figure(figsize=STEP_SIZE)
    ax = sns.pointplot(
        data=raw,
        x="step",
        y="duration_ms",
        hue="mode",
        order=order,
        errorbar="se",
        palette=sns.color_palette("colorblind", n_colors=raw["mode"].nunique()),
        capsize=.4,
        linestyle="none",
        dodge=.35,
    )
    ax.yaxis.label.set_fontsize(15 * STEP_SIZE_RATION)
    ax.xaxis.label.set_fontsize(15 * STEP_SIZE_RATION)
    ax.tick_params(labelsize=12 * STEP_SIZE_RATION)
    plt.ylabel("Queue-proxy Latency (ms)")
    plt.xlabel("Flow Step")
    plt.xticks(rotation=45, ha="right")
    plt.legend(fontsize=12 * STEP_SIZE_RATION, loc="upper left", bbox_to_anchor=(-0.02, 1.035))
    plt.tight_layout()
    plt.savefig(charts_dir / "step_latency_mean.pdf", bbox_inches="tight", pad_inches=0)
    plt.close()

    diff_path = results_dir / "queue-proxy-latency-difference.csv"
    diff = pd.read_csv(diff_path)
    if not diff.empty:
        diff_order = [step for step in order if step in set(diff["step"])]
        plt.figure(figsize=STEP_SIZE)
        ax = sns.pointplot(
            data=diff,
            x="step",
            y="difference_ms",
            order=diff_order,
            errorbar="se",
            linestyle="none",
            color=sns.color_palette("colorblind")[0],
            label="Mean difference ± SE",
            capsize=.4,
        )
        plt.axhline(0, color="black", linewidth=0.8)
        ax.yaxis.label.set_fontsize(15 * STEP_SIZE_RATION)
        ax.xaxis.label.set_fontsize(15 * STEP_SIZE_RATION)
        ax.tick_params(labelsize=12 * STEP_SIZE_RATION)
        plt.ylabel("Queue-proxy Latency Difference (ms)")
        plt.xlabel("Flow Step")
        plt.xticks(rotation=45, ha="right")
        plt.legend(fontsize=12 * STEP_SIZE_RATION, loc="upper left", bbox_to_anchor=(-0.02, 1.035))
        plt.tight_layout()
        plt.savefig(charts_dir / "step_latency_difference.pdf", bbox_inches="tight", pad_inches=0)
        plt.close()

    flows = raw[raw["record_type"] == "flow"]
    if not flows.empty:
        plt.figure(figsize=SIZE)
        ax = sns.pointplot(
            data=flows,
            x="mode",
            y="duration_ms",
            errorbar="se",
            linestyle="none",
            color=sns.color_palette("colorblind")[0],
            label="Mean latency ± SE",
            capsize=.4,
        )
        ax.yaxis.label.set_fontsize(15 * SIZE_RATION)
        ax.xaxis.label.set_fontsize(15 * SIZE_RATION)
        ax.tick_params(labelsize=12 * SIZE_RATION)
        plt.ylabel("Summed Queue-proxy Latency (ms)")
        plt.xlabel("Deployment Mode")
        plt.legend(fontsize=12 * SIZE_RATION, loc="upper left", bbox_to_anchor=(-0.03, 1.055))
        plt.tight_layout()
        plt.savefig(charts_dir / "flow_total_latency.pdf", bbox_inches="tight", pad_inches=0)
        plt.close()

    print(f"Wrote PDF charts under {charts_dir}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results_dir", type=Path, help="Run directory produced by compare-saf-flow-latency.sh")
    parser.add_argument("--warmup", type=int, default=None, help="Override warmup samples to discard per service")
    parser.add_argument("--iterations", type=int, default=None, help="Override measured samples to keep per service")
    parser.add_argument("--no-charts", action="store_true", help="Only write CSV files")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    metadata = read_metadata(args.results_dir)
    warmup = args.warmup if args.warmup is not None else int(metadata.get("warmup", 0))
    iterations = args.iterations if args.iterations is not None else metadata.get("iterations")
    iterations = int(iterations) if iterations is not None else None

    raw_steps = parse_logs(args.results_dir, warmup=warmup, iterations=iterations)
    if raw_steps.empty:
        raise SystemExit(f"No queue-proxy latency entries found under {args.results_dir}")
    raw = add_flow_totals(raw_steps)
    write_tables(args.results_dir, raw)
    if not args.no_charts:
        write_charts(args.results_dir, raw)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

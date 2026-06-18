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
from dataclasses import dataclass
from pathlib import Path

import pandas as pd

COMPARISON = 6.5
SIZE = (10, 3.5)
STEP_SIZE = (12, 6.5)
LAT_RE = re.compile(r'"latency":\s*"([0-9.]+)s"')

SERVICE_TO_STEP = {
    "udr-data-write": "subscriber_write",
    "udm-get-subscriber-data": "subscriber_read",
    "udm-generate-auth-data": "auth_vector",
    "amf-auth-initiate": "amf_auth_initiate",
    "amf-initial-registration": "amf_registration",
    "amf-service-request": "amf_service_request",
    "amf-pdu-session-relay": "amf_pdu_session_relay",
    "smf-pdu-session-create": "smf_pdu_create",
    "smf-pdu-session-update": "smf_pdu_update",
    "smf-pdu-session-release": "smf_pdu_release",
    "amf-deregistration": "amf_deregistration",
    "pcf-policy-create": "pcf_policy_create",
    "nsacf-slice-availability-check": "nsacf_slice_check",
    "bsf-binding-register": "bsf_binding_register",
    "chf-charging-create": "chf_charging_create",
    "nsacf-update-counters": "nsacf_update_counters",
}
DEFAULT_FLOW_SERVICES = [
    "smf-pdu-session-create",
    "pcf-policy-create",
    "nsacf-slice-availability-check",
    "bsf-binding-register",
    "chf-charging-create",
    "nsacf-update-counters",
]


@dataclass(frozen=True)
class ChartConfig:
    comparison_width: float
    summary_size: tuple[float, float]
    step_size: tuple[float, float]
    font_scale: float
    save_pad_inches: float


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


def flow_services(metadata: dict) -> list[str]:
    services = metadata.get("flow_services")
    if isinstance(services, list):
        return [str(service) for service in services if service in SERVICE_TO_STEP]
    return DEFAULT_FLOW_SERVICES


def step_order(services: list[str]) -> list[str]:
    return [SERVICE_TO_STEP[service] for service in services]


def mode_label(mode: str) -> str:
    return "SAF" if mode.lower() == "saf" else mode


def parse_logs(results_dir: Path, services: list[str], warmup: int, iterations: int | None) -> pd.DataFrame:
    records = []
    warnings = []
    for mode_dir in mode_dirs(results_dir):
        mode = mode_dir.name
        for service in services:
            step = SERVICE_TO_STEP[service]
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


def write_charts(results_dir: Path, raw: pd.DataFrame, order_without_total: list[str], config: ChartConfig) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import seaborn as sns

    charts_dir = results_dir / "charts"
    charts_dir.mkdir(exist_ok=True)
    (charts_dir / "saf_overhead_by_step.pdf").unlink(missing_ok=True)
    (charts_dir / "flow_total_latency.pdf").unlink(missing_ok=True)
    (charts_dir / "flow_total_latency_annotated.pdf").unlink(missing_ok=True)
    sns.set(style="whitegrid")

    order = [step for step in order_without_total if step in set(raw["step"])]
    total_step = order_without_total[0]
    label_by_step = (
        raw.sort_values(["record_type", "step"])
        .drop_duplicates("step")
        .set_index("step")["service"]
        .to_dict()
    )
    if total_step in label_by_step:
        label_by_step[total_step] = f"{label_by_step[total_step]}\n(total)"
    plot_raw = raw.copy()
    plot_raw["function"] = plot_raw["step"].map(label_by_step).fillna(plot_raw["step"])
    plot_raw["mode_label"] = plot_raw["mode"].map(mode_label)
    function_order = [label_by_step.get(step, step) for step in order]
    total_function = label_by_step.get(total_step, total_step)
    total_color = sns.color_palette("colorblind")[2]

    for annotated in (False, True):
        fig, ax = plt.subplots(figsize=config.step_size)
        ax = sns.pointplot(
            data=plot_raw,
            x="function",
            y="duration_ms",
            hue="mode_label",
            order=function_order,
            errorbar="se",
            palette=sns.color_palette("colorblind", n_colors=plot_raw["mode_label"].nunique()),
            capsize=.4,
            linestyle="none",
            dodge=.35,
            ax=ax,
        )
        ax.yaxis.label.set_fontsize(15 * config.font_scale)
        ax.xaxis.label.set_fontsize(15 * config.font_scale)
        ax.tick_params(labelsize=12 * config.font_scale)
        ax.set_ylabel("Latency (ms)", labelpad=8)
        ax.set_xlabel("Function", labelpad=8)
        plt.xticks(rotation=45, ha="right")
        center_multiline_tick_labels(ax)
        ax.legend(
            fontsize=12 * config.font_scale,
            loc="upper center",
            bbox_to_anchor=(0.32, 0.98),
            ncol=plot_raw["mode_label"].nunique(),
            title=None,
            frameon=True,
        )
        if annotated:
            annotate_points(ax, plot_raw, "function", "duration_ms", function_order, config, hue_col="mode_label", rotation=90)
        fig.tight_layout()
        suffix = "_annotated" if annotated else ""
        fig.savefig(charts_dir / f"step_latency_mean{suffix}.pdf", bbox_inches="tight", pad_inches=config.save_pad_inches)
        plt.close()

    diff_path = results_dir / "queue-proxy-latency-difference.csv"
    diff = pd.read_csv(diff_path)
    if not diff.empty:
        diff_order = [step for step in order if step in set(diff["step"])]
        diff_function_order = [label_by_step.get(step, step) for step in diff_order]
        diff = diff.copy()
        diff["function"] = diff["step"].map(label_by_step).fillna(diff["step"])
        diff["difference_group"] = diff["step"].apply(lambda step: "Total" if step == total_step else "Function")
        for annotated in (False, True):
            fig, ax = plt.subplots(figsize=config.step_size)
            ax = sns.pointplot(
                data=diff,
                x="function",
                y="difference_ms",
                hue="difference_group",
                hue_order=["Total", "Function"],
                order=diff_function_order,
                errorbar="se",
                linestyle="none",
                palette=[total_color, sns.color_palette("colorblind")[0]],
                capsize=.4,
                dodge=False,
                ax=ax,
            )
            ax.axhline(0, color="black", linewidth=0.8)
            ax.yaxis.label.set_fontsize(15 * config.font_scale)
            ax.xaxis.label.set_fontsize(15 * config.font_scale)
            ax.tick_params(labelsize=12 * config.font_scale)
            ax.set_ylabel("Latency Difference (ms)", labelpad=8)
            ax.set_xlabel("Function", labelpad=8)
            plt.xticks(rotation=45, ha="right")
            center_multiline_tick_labels(ax)
            ax.legend(
                fontsize=12 * config.font_scale,
                loc="upper center",
                bbox_to_anchor=(0.5, 0.98),
                ncol=2,
                title=None,
                frameon=True,
            )
            if annotated:
                annotate_points(ax, diff, "function", "difference_ms", diff_function_order, config, rotation=0)
            fig.tight_layout()
            suffix = "_annotated" if annotated else ""
            fig.savefig(charts_dir / f"step_latency_difference{suffix}.pdf", bbox_inches="tight", pad_inches=config.save_pad_inches)
            plt.close()

    print(f"Wrote PDF charts under {charts_dir}")


def center_multiline_tick_labels(ax) -> None:
    for tick in ax.get_xticklabels():
        tick.set_multialignment("center")


def stderr(values: pd.Series) -> float:
    return float(values.std(ddof=1) / math.sqrt(len(values))) if len(values) > 1 else 0.0


def annotate_points(
    ax,
    data: pd.DataFrame,
    x_col: str,
    y_col: str,
    order: list[str],
    config: ChartConfig,
    hue_col: str | None = None,
    rotation: int = 90,
) -> None:
    y_min, y_max = ax.get_ylim()
    y_span = y_max - y_min if y_max > y_min else 1.0
    text_size = max(6, 7.5 * config.font_scale)

    if hue_col:
        hue_order = list(data[hue_col].drop_duplicates())
        if len(hue_order) == 1:
            offsets = {hue_order[0]: 0.0}
        else:
            step = 0.35 / (len(hue_order) - 1)
            offsets = {hue: -0.175 + index * step for index, hue in enumerate(hue_order)}
        for x_index, x_value in enumerate(order):
            for hue in hue_order:
                values = data[(data[x_col] == x_value) & (data[hue_col] == hue)][y_col].astype(float)
                if values.empty:
                    continue
                mean = float(values.mean())
                se = stderr(values)
                ax.text(
                    x_index + offsets[hue],
                    mean + se + 0.025 * y_span,
                    f"{mean:.2f} ± {se:.2f}",
                    ha="center",
                    va="bottom",
                    fontsize=text_size,
                    rotation=rotation,
                )
    else:
        for x_index, x_value in enumerate(order):
            values = data[data[x_col] == x_value][y_col].astype(float)
            if values.empty:
                continue
            mean = float(values.mean())
            se = stderr(values)
            ax.text(
                x_index,
                mean + se + 0.025 * y_span,
                f"{mean:.2f} ± {se:.2f}",
                ha="center",
                va="bottom",
                fontsize=text_size,
                rotation=rotation,
            )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results_dir", type=Path, help="Run directory produced by compare-saf-flow-latency.sh")
    parser.add_argument("--warmup", type=int, default=None, help="Override warmup samples to discard per service")
    parser.add_argument("--iterations", type=int, default=None, help="Override measured samples to keep per service")
    parser.add_argument("--no-charts", action="store_true", help="Only write CSV files")
    parser.add_argument("--comparison-width", type=float, default=COMPARISON, help="Reference width used to compute SAF-style font scaling")
    parser.add_argument("--step-width", type=float, default=STEP_SIZE[0], help="Width in inches for step latency graphs")
    parser.add_argument("--step-height", type=float, default=STEP_SIZE[1], help="Height in inches for step latency graphs")
    parser.add_argument("--summary-width", type=float, default=SIZE[0], help="Width in inches for flow total graph")
    parser.add_argument("--summary-height", type=float, default=SIZE[1], help="Height in inches for flow total graph")
    parser.add_argument("--font-scale", type=float, default=None, help="Override font scale; default is summary-width / comparison-width")
    parser.add_argument("--save-pad-inches", type=float, default=0.12, help="Padding used when saving charts with tight bounding boxes")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    metadata = read_metadata(args.results_dir)
    warmup = args.warmup if args.warmup is not None else int(metadata.get("warmup", 0))
    iterations = args.iterations if args.iterations is not None else metadata.get("iterations")
    iterations = int(iterations) if iterations is not None else None
    services = flow_services(metadata)
    order_without_total = step_order(services)
    font_scale = args.font_scale if args.font_scale is not None else args.summary_width / args.comparison_width
    chart_config = ChartConfig(
        comparison_width=args.comparison_width,
        summary_size=(args.summary_width, args.summary_height),
        step_size=(args.step_width, args.step_height),
        font_scale=font_scale,
        save_pad_inches=args.save_pad_inches,
    )

    raw_steps = parse_logs(args.results_dir, services=services, warmup=warmup, iterations=iterations)
    if raw_steps.empty:
        raise SystemExit(f"No queue-proxy latency entries found under {args.results_dir}")
    raw = raw_steps
    write_tables(args.results_dir, raw)
    if not args.no_charts:
        write_charts(args.results_dir, raw, order_without_total, chart_config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

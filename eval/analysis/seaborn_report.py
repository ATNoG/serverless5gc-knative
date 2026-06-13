#!/usr/bin/env python3
"""
Build the evaluation summary and all graphs from Prometheus exports.

This is the single reporting entry point for Knative evaluation results. It
reads eval/results/<target>/<scenario>/runN/ directories, writes summary CSV
files, and generates seaborn PNG charts under eval/results/charts/.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

os.environ.setdefault("MPLCONFIGDIR", str(Path("/tmp/serverless5gc-matplotlib")))

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns

LAMBDA_PRICE_PER_GB_SEC = 0.0000166667
LAMBDA_PRICE_PER_REQUEST = 0.0000002
FARGATE_PRICE_PER_VCPU_HR = 0.04048
FARGATE_PRICE_PER_GB_HR = 0.004445
BASELINE_VCPUS = 8
BASELINE_MEMORY_GB = 16
DEFAULT_FUNCTION_MEMORY_MB = 128
SCENARIO_ORDER = ["idle", "low", "medium", "high", "burst"]


@dataclass
class RunSummary:
    scenario: str
    target: str
    run: int
    duration_minutes: float
    ue_count: int
    registration_rate: float
    pdu_sessions_per_ue: int
    total_invocations: float
    avg_duration_seconds: float
    total_cpu_seconds: float
    peak_memory_mb: float
    avg_memory_mb: float
    projected_cost_usd: float
    cost_model: str


def load_prometheus(path: Path) -> list[dict[str, Any]]:
    try:
        payload = json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return []
    if payload.get("status") != "success":
        return []
    return payload.get("data", {}).get("result", [])


def values(series: dict[str, Any]) -> list[tuple[float, float]]:
    parsed = []
    for row in series.get("values", []):
        try:
            parsed.append((float(row[0]), float(row[1])))
        except (IndexError, TypeError, ValueError):
            continue
    return parsed


def counter_delta(results: list[dict[str, Any]]) -> float:
    total = 0.0
    for series in results:
        points = values(series)
        if not points:
            continue
        if len(points) == 1:
            total += points[-1][1]
            continue
        first = points[0][1]
        last = points[-1][1]
        total += last - first if last >= first else last
    return total


def max_value(results: list[dict[str, Any]]) -> float:
    maximum = 0.0
    for series in results:
        for _, value in values(series):
            maximum = max(maximum, value)
    return maximum


def avg_value(results: list[dict[str, Any]]) -> float:
    total = 0.0
    count = 0
    for series in results:
        for _, value in values(series):
            total += value
            count += 1
    return total / count if count else 0.0


def projected_lambda_cost(invocations: float, avg_duration_s: float) -> float:
    gb_seconds = invocations * avg_duration_s * (DEFAULT_FUNCTION_MEMORY_MB / 1024.0)
    return gb_seconds * LAMBDA_PRICE_PER_GB_SEC + invocations * LAMBDA_PRICE_PER_REQUEST


def projected_fargate_cost(duration_minutes: float) -> float:
    duration_hours = duration_minutes / 60.0
    return (
        BASELINE_VCPUS * FARGATE_PRICE_PER_VCPU_HR * duration_hours
        + BASELINE_MEMORY_GB * FARGATE_PRICE_PER_GB_HR * duration_hours
    )


def analyze_run(run_dir: Path) -> RunSummary | None:
    metadata_path = run_dir / "metadata.json"
    if not metadata_path.exists():
        return None

    metadata = json.loads(metadata_path.read_text())
    invocations = load_prometheus(run_dir / "serverless5gc_function_invocations_total.json")
    duration_sum = load_prometheus(run_dir / "serverless5gc_function_duration_seconds_sum.json")
    duration_count = load_prometheus(run_dir / "serverless5gc_function_duration_seconds_count.json")
    cpu = load_prometheus(run_dir / "container_cpu_usage_seconds_total.json")
    memory = load_prometheus(run_dir / "container_memory_usage_bytes.json")

    total_invocations = counter_delta(invocations)
    total_duration = counter_delta(duration_sum)
    total_count = counter_delta(duration_count)
    avg_duration = total_duration / total_count if total_count else 0.0

    target = str(metadata.get("target", "unknown"))
    duration_minutes = float(metadata.get("duration_minutes", 0))
    if target.startswith("serverless"):
        cost = projected_lambda_cost(total_invocations, avg_duration)
        cost_model = "lambda"
    else:
        cost = projected_fargate_cost(duration_minutes)
        cost_model = "fargate"

    return RunSummary(
        scenario=str(metadata.get("scenario", run_dir.parent.name)),
        target=target,
        run=int(metadata.get("run", run_dir.name.removeprefix("run") or 0)),
        duration_minutes=duration_minutes,
        ue_count=int(metadata.get("ue_count", 0)),
        registration_rate=float(metadata.get("registration_rate", 0)),
        pdu_sessions_per_ue=int(metadata.get("pdu_sessions_per_ue", 0)),
        total_invocations=total_invocations,
        avg_duration_seconds=avg_duration,
        total_cpu_seconds=counter_delta(cpu),
        peak_memory_mb=max_value(memory) / (1024 * 1024),
        avg_memory_mb=avg_value(memory) / (1024 * 1024),
        projected_cost_usd=cost,
        cost_model=cost_model,
    )


def collect_function_metrics(results_dir: Path) -> pd.DataFrame:
    rows = []
    for run_dir in sorted(results_dir.glob("*/*/run*")):
        metadata_path = run_dir / "metadata.json"
        if not metadata_path.exists():
            continue
        metadata = json.loads(metadata_path.read_text())
        invocations = load_prometheus(run_dir / "serverless5gc_function_invocations_total.json")
        duration_sum = load_prometheus(run_dir / "serverless5gc_function_duration_seconds_sum.json")
        duration_count = load_prometheus(run_dir / "serverless5gc_function_duration_seconds_count.json")

        duration_by_name = {}
        for series in duration_sum:
            name = metric_name(series)
            duration_by_name.setdefault(name, {"sum": 0.0, "count": 0.0})
            duration_by_name[name]["sum"] += counter_delta([series])
        for series in duration_count:
            name = metric_name(series)
            duration_by_name.setdefault(name, {"sum": 0.0, "count": 0.0})
            duration_by_name[name]["count"] += counter_delta([series])

        for series in invocations:
            name = metric_name(series)
            count = counter_delta([series])
            duration = duration_by_name.get(name, {"sum": 0.0, "count": 0.0})
            rows.append(
                {
                    "target": metadata.get("target", run_dir.parents[1].name),
                    "scenario": metadata.get("scenario", run_dir.parent.name),
                    "run": metadata.get("run", run_dir.name.removeprefix("run")),
                    "function": name,
                    "invocations": count,
                    "avg_duration_ms": (
                        duration["sum"] / duration["count"] * 1000
                        if duration["count"]
                        else 0.0
                    ),
                }
            )
    return pd.DataFrame(rows)


def metric_name(series: dict[str, Any]) -> str:
    metric = series.get("metric", {})
    return (
        metric.get("function")
        or metric.get("function_name")
        or metric.get("service")
        or metric.get("ksvc")
        or metric.get("container")
        or "unknown"
    )


def collect_summaries(results_dir: Path) -> list[RunSummary]:
    summaries = []
    for run_dir in sorted(results_dir.glob("*/*/run*")):
        if run_dir.is_dir():
            summary = analyze_run(run_dir)
            if summary:
                summaries.append(summary)
    return summaries


def write_csv(path: Path, rows: list[RunSummary]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(asdict(rows[0]).keys()))
        writer.writeheader()
        for row in rows:
            writer.writerow(asdict(row))


def save_plot(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    plt.tight_layout()
    plt.savefig(path, dpi=180)
    plt.close()


def apply_style() -> None:
    sns.set_theme(
        context="paper",
        style="whitegrid",
        palette="colorblind",
        rc={
            "figure.figsize": (9, 5),
            "axes.spines.top": False,
            "axes.spines.right": False,
            "savefig.bbox": "tight",
        },
    )


def plot_summary_charts(summary: pd.DataFrame, charts_dir: Path) -> None:
    summary = summary.copy()
    summary["scenario"] = pd.Categorical(summary["scenario"], SCENARIO_ORDER, ordered=True)
    summary["avg_duration_ms"] = summary["avg_duration_seconds"] * 1000

    chart_specs = [
        ("projected_cost_usd", "Projected Cost (USD)", "cost_by_scenario.png"),
        ("total_invocations", "Function Invocations", "invocations_by_scenario.png"),
        ("avg_duration_ms", "Average Function Duration (ms)", "duration_by_scenario.png"),
        ("total_cpu_seconds", "Container CPU Seconds", "cpu_by_scenario.png"),
        ("peak_memory_mb", "Peak Memory (MiB)", "memory_by_scenario.png"),
    ]

    for y_col, y_label, filename in chart_specs:
        plt.figure(figsize=(9, 5))
        sns.barplot(data=summary, x="scenario", y=y_col, hue="target", errorbar="sd")
        plt.xlabel("Scenario")
        plt.ylabel(y_label)
        plt.legend(title="Target")
        save_plot(charts_dir / filename)

    active = summary[summary["scenario"] != "idle"]
    if not active.empty:
        plt.figure(figsize=(9, 5))
        sns.lineplot(
            data=active.sort_values("ue_count"),
            x="ue_count",
            y="projected_cost_usd",
            hue="target",
            style="scenario",
            markers=True,
            dashes=False,
            errorbar="sd",
        )
        plt.xlabel("UE Count")
        plt.ylabel("Projected Cost (USD)")
        plt.legend(title="Target / Scenario")
        save_plot(charts_dir / "cost_scaling.png")


def plot_function_charts(functions: pd.DataFrame, charts_dir: Path) -> None:
    if functions.empty:
        return

    functions = functions[functions["invocations"] > 0].copy()
    if functions.empty:
        return
    functions["scenario"] = pd.Categorical(functions["scenario"], SCENARIO_ORDER, ordered=True)

    top = (
        functions.groupby("function", as_index=False)["invocations"]
        .sum()
        .sort_values("invocations", ascending=False)
        .head(15)["function"]
    )
    top_functions = functions[functions["function"].isin(top)]

    plt.figure(figsize=(11, 6))
    sns.barplot(
        data=top_functions,
        y="function",
        x="invocations",
        hue="scenario",
        estimator=sum,
        errorbar=None,
    )
    plt.xlabel("Invocations")
    plt.ylabel("Function")
    plt.legend(title="Scenario")
    save_plot(charts_dir / "top_function_invocations.png")

    heatmap_data = (
        top_functions.pivot_table(
            index="function",
            columns="scenario",
            values="avg_duration_ms",
            aggfunc="mean",
            observed=False,
        )
        .fillna(0)
        .reindex(columns=SCENARIO_ORDER)
    )
    plt.figure(figsize=(9, max(4, len(heatmap_data) * 0.35)))
    sns.heatmap(heatmap_data, cmap="viridis", linewidths=0.3, cbar_kws={"label": "ms"})
    plt.xlabel("Scenario")
    plt.ylabel("Function")
    save_plot(charts_dir / "function_duration_heatmap.png")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results_dir", nargs="?", default="eval/results")
    parser.add_argument("--output-dir", default=None)
    args = parser.parse_args()

    results_dir = Path(args.results_dir)
    charts_dir = Path(args.output_dir) if args.output_dir else results_dir / "charts"
    summaries = collect_summaries(results_dir)
    if not summaries:
        print(f"No result runs found under {results_dir}")
        return 1

    summary_csv = results_dir / "summary.csv"
    write_csv(summary_csv, summaries)
    summary = pd.DataFrame([asdict(row) for row in summaries])
    function_metrics = collect_function_metrics(results_dir)
    if not function_metrics.empty:
        function_metrics.to_csv(results_dir / "function_metrics.csv", index=False)

    apply_style()
    plot_summary_charts(summary, charts_dir)
    plot_function_charts(function_metrics, charts_dir)

    print(f"Wrote {summary_csv}")
    if not function_metrics.empty:
        print(f"Wrote {results_dir / 'function_metrics.csv'}")
    print(f"Wrote charts to {charts_dir}")
    print(summary.sort_values(["target", "scenario", "run"]).to_string(index=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

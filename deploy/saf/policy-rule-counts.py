#!/usr/bin/env python3
"""Report SAF rule counts per rendered Knative Service."""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from typing import Any


def load_catalog(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def count_service_rules(catalog: dict[str, Any], service: str) -> dict[str, Any]:
    spec = catalog["functions"][service]
    common_name = spec.get("common", "post-json")
    common_rules = len(catalog["common"].get(common_name, []))
    profile_rules = 0
    profile_names = spec.get("profiles", [])

    for profile_name in profile_names:
        profile = catalog["profiles"][profile_name]
        if profile.get("common"):
            common_name = profile["common"]
            common_rules = len(catalog["common"][common_name])
        profile_rules += len(profile.get("rules", []))

    allowlist_rules = 1 if spec.get("allowed_keys") else 0
    function_rules = len(spec.get("rules", []))
    total_rules = common_rules + allowlist_rules + profile_rules + function_rules

    return {
        "service": service,
        "common_policy": common_name,
        "common_rules": common_rules,
        "allowlist_rules": allowlist_rules,
        "profile_rules": profile_rules,
        "function_rules": function_rules,
        "total_rules": total_rules,
        "profiles": ",".join(profile_names),
    }


def rows(catalog: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        count_service_rules(catalog, service)
        for service in sorted(catalog["functions"])
    ]


def write_csv(rows_: list[dict[str, Any]], output) -> None:
    writer = csv.DictWriter(output, fieldnames=list(rows_[0].keys()), lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows_)


def write_markdown(rows_: list[dict[str, Any]], output) -> None:
    columns = ["service", "common_policy", "common_rules", "allowlist_rules", "profile_rules", "function_rules", "total_rules"]
    output.write("| " + " | ".join(columns) + " |\n")
    output.write("| " + " | ".join("---" for _ in columns) + " |\n")
    for row in rows_:
        output.write("| " + " | ".join(str(row[column]) for column in columns) + " |\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--policies",
        default=Path(__file__).with_name("policies.json"),
        type=Path,
        help="Path to the SAF policy catalog.",
    )
    parser.add_argument(
        "--format",
        choices=("csv", "markdown"),
        default="csv",
        help="Output format.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Output file. Defaults to stdout.",
    )
    args = parser.parse_args()

    catalog = load_catalog(args.policies)
    result_rows = rows(catalog)

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("w", newline="") as handle:
            if args.format == "csv":
                write_csv(result_rows, handle)
            else:
                write_markdown(result_rows, handle)
    else:
        if args.format == "csv":
            write_csv(result_rows, sys.stdout)
        else:
            write_markdown(result_rows, sys.stdout)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

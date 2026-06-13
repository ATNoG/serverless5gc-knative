#!/usr/bin/env bash
# Runs all Knative cluster-local evaluation scenarios and builds the seaborn report.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SCENARIOS="${SCENARIOS:-idle low medium high burst}"
RUNS="${RUNS:-1}"
PYTHON="${PYTHON:-python3}"
export MPLCONFIGDIR="${MPLCONFIGDIR:-${PROJECT_DIR}/.cache/matplotlib}"
mkdir -p "$MPLCONFIGDIR"

echo "=== Knative evaluation suite ==="
echo "Scenarios: ${SCENARIOS}"
echo "Runs per scenario: ${RUNS}"

for RUN in $(seq 1 "$RUNS"); do
    for SCENARIO in $SCENARIOS; do
        "${SCRIPT_DIR}/run-knative-cluster-eval.sh" "$SCENARIO" "$RUN"
    done
done

"${PYTHON}" "${PROJECT_DIR}/eval/analysis/seaborn_report.py" "${PROJECT_DIR}/eval/results"

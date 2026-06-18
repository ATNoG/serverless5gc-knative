#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<EOF
Usage: eval/scripts/render-saf-flow-latency-graphs.sh <results-dir> [plot options]

Regenerates SAF flow latency CSV summaries, vector PDF graphs, and PNG previews
from an existing run directory without rerunning the test.

Default plot options match the graphs used for the paper:
  --step-width 13
  --step-height 7
  --summary-width 10
  --summary-height 4
  --comparison-width 6.5
  --save-pad-inches 0.18

Extra arguments are passed through to plot-saf-flow-latency.py.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

RESULTS_DIR="$1"
shift

PLOT_PYTHON="${PLOT_PYTHON:-}"
if [[ -z "$PLOT_PYTHON" && -x "$PROJECT_DIR/.venv/bin/python" ]]; then
  PLOT_PYTHON="$PROJECT_DIR/.venv/bin/python"
fi
if [[ -z "$PLOT_PYTHON" ]]; then
  PLOT_PYTHON="python3"
fi

DEFAULT_ARGS=(
  --step-width "${STEP_WIDTH:-13}"
  --step-height "${STEP_HEIGHT:-7}"
  --summary-width "${SUMMARY_WIDTH:-10}"
  --summary-height "${SUMMARY_HEIGHT:-4}"
  --comparison-width "${COMPARISON_WIDTH:-6.5}"
  --save-pad-inches "${SAVE_PAD_INCHES:-0.18}"
)

echo "+ MPLCONFIGDIR=${MPLCONFIGDIR:-/tmp/matplotlib-serverless5gc} $PLOT_PYTHON eval/scripts/plot-saf-flow-latency.py $RESULTS_DIR ${DEFAULT_ARGS[*]} $*"
MPLCONFIGDIR="${MPLCONFIGDIR:-/tmp/matplotlib-serverless5gc}" \
  "$PLOT_PYTHON" "$PROJECT_DIR/eval/scripts/plot-saf-flow-latency.py" "$RESULTS_DIR" "${DEFAULT_ARGS[@]}" "$@"

PNG_DIR="$RESULTS_DIR/charts/png"
rm -rf "$PNG_DIR"
mkdir -p "$PNG_DIR"
for pdf in "$RESULTS_DIR"/charts/*.pdf; do
  [[ -e "$pdf" ]] || continue
  base="$(basename "$pdf" .pdf)"
  echo "+ pdftoppm -png -singlefile -r ${PNG_DPI:-300} $pdf $PNG_DIR/$base"
  pdftoppm -png -singlefile -r "${PNG_DPI:-300}" "$pdf" "$PNG_DIR/$base"
done

find "$RESULTS_DIR/charts" -maxdepth 2 -type f \( -name '*.pdf' -o -name '*.png' \) -print | sort

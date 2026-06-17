#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAMESPACE="${NAMESPACE:-default}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-cluster.local}"
REGISTRY="${REGISTRY:-ghcr.io/atnog/serverless5gc-knative}"
TAG="${TAG:-latest}"
KAFKA_BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_SERVERS:-my-cluster-kafka-bootstrap.kafka:9092}"
BASE_RESULT_DIR="${BASE_RESULT_DIR:-$PROJECT_DIR/eval/results/saf-flow-latency}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RESULTS_DIR="${RESULTS_DIR:-$BASE_RESULT_DIR/$RUN_ID}"
MODES="${MODES:-baseline saf}"
ITERATIONS="${ITERATIONS:-30}"
WARMUP="${WARMUP:-5}"
WAIT_PERIOD="${WAIT_PERIOD:-0}"
SKIP_DEPLOY="${SKIP_DEPLOY:-false}"
GENERATE_GRAPHS="${GENERATE_GRAPHS:-true}"
KNATIVE_EXTERNAL_IP="${KNATIVE_EXTERNAL_IP:-${EXTERNAL_IP:-}}"
KNATIVE_URL_TEMPLATE="${KNATIVE_URL_TEMPLATE:-}"
BASELINE_QUEUE_PROXY_IMAGE="${BASELINE_QUEUE_PROXY_IMAGE:-}"
QUEUE_PROXY_IMAGE="${QUEUE_PROXY_IMAGE:-ghcr.io/atnog/serverless-workflow-firewall/queue:latest}"

ENTRY_SERVICE="${ENTRY_SERVICE:-smf-pdu-session-create}"

FLOW_SERVICES=(
  smf-pdu-session-create
  pcf-policy-create
  nsacf-slice-availability-check
  bsf-binding-register
  chf-charging-create
  nsacf-update-counters
)

usage() {
  cat <<EOF
Usage: env [options] eval/scripts/compare-saf-flow-latency.sh

External-machine SAF flow latency runner. Primary latency is measured later from
Knative queue-proxy logs, matching the SAF latency tests. This script deploys,
sends one request to the public SMF entrypoint, and saves queue-proxy/user logs
for the entrypoint and the services it invokes internally.

Main environment variables:
  MODES="baseline saf"              Modes to run: baseline, saf, current
  ITERATIONS=30                     Measured flow iterations per mode
  WARMUP=5                          Warmup flow iterations per mode
  NAMESPACE=default                 Kubernetes namespace
  SKIP_DEPLOY=false                 Do not redeploy, only test current cluster
  KNATIVE_EXTERNAL_IP=<ip>          Build http://service.namespace.ip.sslip.io URLs
  KNATIVE_URL_TEMPLATE=<template>   e.g. https://{service}.{namespace}.example.com
  BASELINE_QUEUE_PROXY_IMAGE=<img>  Standard Knative queue-proxy image
  QUEUE_PROXY_IMAGE=<img>           SAF queue-proxy image
  GENERATE_GRAPHS=true             Run plot-saf-flow-latency.py at the end
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

run() {
  echo "+ $*"
  "$@"
}

patch_queue_image() {
  local image="$1"
  [[ -z "$image" ]] && return 0
  run kubectl patch configmap config-deployment -n knative-serving --type merge \
    -p "{\"data\":{\"queue-sidecar-image\":\"$image\"}}"
}

deploy_mode() {
  local mode="$1"
  if [[ "$SKIP_DEPLOY" == "true" || "$mode" == "current" ]]; then
    return 0
  fi

  if [[ "$mode" == "baseline" ]]; then
    if [[ -z "$BASELINE_QUEUE_PROXY_IMAGE" ]]; then
      echo "WARNING: BASELINE_QUEUE_PROXY_IMAGE is unset; the cluster may still use the SAF queue-proxy." >&2
    else
      patch_queue_image "$BASELINE_QUEUE_PROXY_IMAGE"
    fi
    run env NAMESPACE="$NAMESPACE" CLUSTER_DOMAIN="$CLUSTER_DOMAIN" REGISTRY="$REGISTRY" TAG="$TAG" \
      KAFKA_BOOTSTRAP_SERVERS="$KAFKA_BOOTSTRAP_SERVERS" \
      "$PROJECT_DIR/scripts/deploy-knative.sh"
  elif [[ "$mode" == "saf" ]]; then
    run env NAMESPACE="$NAMESPACE" CLUSTER_DOMAIN="$CLUSTER_DOMAIN" REGISTRY="$REGISTRY" TAG="$TAG" \
      KAFKA_BOOTSTRAP_SERVERS="$KAFKA_BOOTSTRAP_SERVERS" QUEUE_PROXY_IMAGE="$QUEUE_PROXY_IMAGE" \
      PATCH_SAF_QUEUE_PROXY=true \
      "$PROJECT_DIR/deploy/saf/deploy-saf.sh"
  else
    echo "Unsupported mode: $mode" >&2
    exit 1
  fi
}

wait_for_services() {
  run kubectl wait ksvc -n "$NAMESPACE" -l app.kubernetes.io/part-of=serverless5gc \
    --for=condition=Ready --timeout=300s
}

ensure_public_entrypoint() {
  local service="$ENTRY_SERVICE"
  kubectl label ksvc "$service" -n "$NAMESPACE" networking.knative.dev/visibility- --overwrite >/dev/null 2>&1 || true
  kubectl label route "$service" -n "$NAMESPACE" networking.knative.dev/visibility- --overwrite >/dev/null 2>&1 || true
}

service_url() {
  local service="$1"
  if [[ -n "$KNATIVE_URL_TEMPLATE" ]]; then
    local url="$KNATIVE_URL_TEMPLATE"
    url="${url//\{service\}/$service}"
    url="${url//\{namespace\}/$NAMESPACE}"
    url="${url//\{external_ip\}/$KNATIVE_EXTERNAL_IP}"
    echo "${url%/}"
  elif [[ -n "$KNATIVE_EXTERNAL_IP" ]]; then
    echo "http://$service.$NAMESPACE.$KNATIVE_EXTERNAL_IP.sslip.io"
  else
    kubectl get ksvc "$service" -n "$NAMESPACE" -o jsonpath='{.status.url}'
  fi
}

post_json() {
  local mode="$1" phase="$2" iteration="$3" step="$4" service="$5" payload="$6" expect="$7"
  local url body_file code start_ms end_ms
  url="$(service_url "$service")"
  body_file="$RESULTS_DIR/$mode/responses/${phase}_${iteration}_${step}.json"
  mkdir -p "$(dirname "$body_file")"
  start_ms="$(date +%s%3N)"
  code="$(curl -sS -o "$body_file" -w "%{http_code}" -X POST "$url" -H 'Content-Type: application/json' --data "$payload")"
  end_ms="$(date +%s%3N)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$mode" "$phase" "$iteration" "$step" "$service" "$url" "$code" "$start_ms" "$end_ms" "$((end_ms - start_ms))" \
    >> "$RESULTS_DIR/client-trace.csv"

  if [[ ",$expect," != *",$code,"* ]]; then
    echo "Request failed: mode=$mode phase=$phase iteration=$iteration step=$step service=$service status=$code" >&2
    sed -n '1,120p' "$body_file" >&2 || true
    exit 1
  fi
  echo "$body_file"
}

run_flow() {
  local mode="$1" phase="$2" iteration="$3"
  local supi
  supi="$(printf 'imsi-00101088%07d' "$iteration")"

  post_json "$mode" "$phase" "$iteration" smf_pdu_create "$ENTRY_SERVICE" \
    "{\"supi\":\"$supi\",\"pdu_session_id\":1,\"dnn\":\"internet\",\"snssai\":{\"sst\":1,\"sd\":\"010203\"}}" \
    "201" >/dev/null
}

collect_logs() {
  local mode="$1" since_time="$2" service pod service_dir
  for service in "${FLOW_SERVICES[@]}"; do
    service_dir="$RESULTS_DIR/$mode/logs/$service"
    mkdir -p "$service_dir"
    while read -r pod; do
      [[ -z "$pod" ]] && continue
      kubectl logs "$pod" -n "$NAMESPACE" -c queue-proxy --since-time="$since_time" > "$service_dir/pod_${pod}_queue_proxy_logs.txt" || true
      kubectl logs "$pod" -n "$NAMESPACE" -c user-container --since-time="$since_time" > "$service_dir/pod_${pod}_user_container_logs.txt" || true
    done < <(kubectl get pods -n "$NAMESPACE" -l "serving.knative.dev/service=$service" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  done
}

mkdir -p "$RESULTS_DIR"
printf 'mode,phase,iteration,step,service,url,status_code,start_ms,end_ms,client_elapsed_ms\n' > "$RESULTS_DIR/client-trace.csv"
cat > "$RESULTS_DIR/metadata.json" <<EOF
{
  "run_id": "$RUN_ID",
  "namespace": "$NAMESPACE",
  "modes": "$(echo "$MODES" | tr '\n' ' ')",
  "iterations": $ITERATIONS,
  "warmup": $WARMUP,
  "wait_period": $WAIT_PERIOD,
  "entry_service": "$ENTRY_SERVICE",
  "latency_source": "queue-proxy logs",
  "client_trace": "diagnostic only",
  "flow_services": [$(printf '"%s",' "${FLOW_SERVICES[@]}" | sed 's/,$//')]
}
EOF

for mode in $MODES; do
  mode_start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$RESULTS_DIR/$mode/responses"
  deploy_mode "$mode"
  wait_for_services
  ensure_public_entrypoint

  echo "Public Knative entrypoint for $mode:"
  echo "  $ENTRY_SERVICE: $(service_url "$ENTRY_SERVICE")"

  for ((i = 1; i <= WARMUP; i++)); do
    run_flow "$mode" warmup "$i"
    [[ "$WAIT_PERIOD" != "0" ]] && sleep "$WAIT_PERIOD"
  done
  for ((i = 1; i <= ITERATIONS; i++)); do
    run_flow "$mode" measure "$i"
    [[ "$WAIT_PERIOD" != "0" ]] && sleep "$WAIT_PERIOD"
  done
  sleep 15
  collect_logs "$mode" "$mode_start"
done

if [[ "$GENERATE_GRAPHS" == "true" ]]; then
  "$PROJECT_DIR/eval/scripts/plot-saf-flow-latency.py" "$RESULTS_DIR"
fi

echo "SAF flow latency run complete: $RESULTS_DIR"

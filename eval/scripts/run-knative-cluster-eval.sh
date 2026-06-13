#!/usr/bin/env bash
# Runs a Knative HTTP evaluation from inside the Kubernetes cluster and exports
# Prometheus metrics into eval/results/serverless-cluster/<scenario>/runN.

set -euo pipefail

SCENARIO="${1:-low}"
RUN="${2:-1}"
NAMESPACE="${NAMESPACE:-default}"
PROM_NAMESPACE="${PROM_NAMESPACE:-monitoring}"
PROM_SERVICE="${PROM_SERVICE:-prometheus}"
LOAD_IMAGE="${LOAD_IMAGE:-curlimages/curl:8.11.1}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-cluster.local}"
EVAL_WAIT_EXTRA_SECONDS="${EVAL_WAIT_EXTRA_SECONDS:-900}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCENARIO_FILE="${PROJECT_DIR}/eval/scenarios/${SCENARIO}.yaml"
RESULTS_DIR="${PROJECT_DIR}/eval/results/serverless-cluster/${SCENARIO}/run${RUN}"

if [ ! -f "$SCENARIO_FILE" ]; then
    echo "ERROR: Scenario file not found: ${SCENARIO_FILE}" >&2
    exit 1
fi

mkdir -p "$RESULTS_DIR"

UE_COUNT="$(grep 'count:' "$SCENARIO_FILE" | head -1 | awk '{print $2}')"
REG_RATE="$(grep 'registration_rate_per_sec:' "$SCENARIO_FILE" | head -1 | awk '{print $2}')"
DURATION="$(grep 'duration_minutes:' "$SCENARIO_FILE" | head -1 | awk '{print $2}')"
PDU_SESSIONS="$(grep 'pdu_sessions_per_ue:' "$SCENARIO_FILE" | head -1 | awk '{print $2}')"
if [ -n "${EVAL_DURATION_MINUTES:-}" ]; then
    DURATION="$EVAL_DURATION_MINUTES"
fi

JOB_NAME="s5gc-eval-${SCENARIO}-run${RUN}"
TMP_JOB="$(mktemp)"
PF_PID=""

cleanup() {
    if [ -n "$PF_PID" ]; then
        kill "$PF_PID" >/dev/null 2>&1 || true
    fi
    rm -f "$TMP_JOB"
}
trap cleanup EXIT

echo "=== Knative cluster evaluation: ${SCENARIO} run${RUN} ==="
echo "UEs: ${UE_COUNT}, rate: ${REG_RATE}/s, duration: ${DURATION}min, PDU sessions/UE: ${PDU_SESSIONS}"

kubectl wait ksvc -n "$NAMESPACE" \
    -l app.kubernetes.io/component=procedure-function \
    --for=condition=Ready \
    --timeout=300s
kubectl rollout status deployment/prometheus -n "$PROM_NAMESPACE" --timeout=180s

kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found=true >/dev/null

START_TIME="$(date -Iseconds)"
echo "$START_TIME" > "${RESULTS_DIR}/start_time"

cat > "$TMP_JOB" << YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/part-of: serverless5gc
        app.kubernetes.io/component: eval-loadgen
    spec:
      restartPolicy: Never
      containers:
        - name: loadgen
          image: ${LOAD_IMAGE}
          command: ["sh", "-ec"]
          args:
            - |
              UE_COUNT=${UE_COUNT}
              REG_RATE=${REG_RATE}
              DURATION_SECS=$(( ${DURATION} * 60 ))
              PDU_SESSIONS=${PDU_SESSIONS}
              NAMESPACE=${NAMESPACE}
              CLUSTER_DOMAIN=${CLUSTER_DOMAIN}
              STARTED=0
              START_TS=\$(date +%s)

              if [ "\$UE_COUNT" -eq 0 ]; then
                sleep "\$DURATION_SECS"
                exit 0
              fi

              while [ "\$STARTED" -lt "\$UE_COUNT" ]; do
                BATCH="\$REG_RATE"
                [ "\$BATCH" -le 0 ] && BATCH=1
                REMAINING=\$((UE_COUNT - STARTED))
                [ "\$BATCH" -gt "\$REMAINING" ] && BATCH="\$REMAINING"

                for i in \$(seq 1 "\$BATCH"); do
                  IMSI_NUM=\$((STARTED + i))
                  SUPI=\$(printf "imsi-001010%09d" "\$IMSI_NUM")
                  printf '{"supi":"%s","auth_data":{"auth_method":"5G_AKA","k":"Rltc6LGZtJ+qXwou4jimvA==","opc":"6O0oneupUuQoO1TojmGDyg==","amf":"gAA=","sqn":"AAAAAAAg"},"access_mobility_data":{"nssai":[{"sst":1,"sd":"010203"}],"default_dnn":"internet"},"session_management":[{"snssai":{"sst":1,"sd":"010203"},"dnn":"internet","qos_ref":9}]}\n' "\$SUPI" > /tmp/subscriber-\$IMSI_NUM.json
                  curl -fsS -X POST "http://udr-data-write.\$NAMESPACE.svc.\$CLUSTER_DOMAIN" \
                    -H "Content-Type: application/json" --data @/tmp/subscriber-\$IMSI_NUM.json >/dev/null
                  curl -fsS -X POST "http://amf-initial-registration.\$NAMESPACE.svc.\$CLUSTER_DOMAIN" \
                    -H "Content-Type: application/json" \
                    -d "{\"supi\":\"\$SUPI\",\"ran_ue_ngap_id\":\$IMSI_NUM,\"registration_type\":1,\"skip_auth\":true}" >/dev/null
                  for p in \$(seq 1 "\$PDU_SESSIONS"); do
                    curl -fsS -X POST "http://smf-pdu-session-create.\$NAMESPACE.svc.\$CLUSTER_DOMAIN" \
                      -H "Content-Type: application/json" \
                      -d "{\"supi\":\"\$SUPI\",\"pdu_session_id\":\$p,\"dnn\":\"internet\",\"snssai\":{\"sst\":1,\"sd\":\"010203\"}}" >/dev/null
                  done
                done

                STARTED=\$((STARTED + BATCH))
                echo "sent \$STARTED/\$UE_COUNT UE workflows"
                sleep 1
              done

              NOW=\$(date +%s)
              ELAPSED=\$((NOW - START_TS))
              REMAIN=\$((DURATION_SECS - ELAPSED))
              [ "\$REMAIN" -gt 0 ] && sleep "\$REMAIN"
YAML

kubectl apply -f "$TMP_JOB"
WAIT_TIMEOUT="$((DURATION * 60 + UE_COUNT / (REG_RATE > 0 ? REG_RATE : 1) + EVAL_WAIT_EXTRA_SECONDS))s"
if ! kubectl wait job/"$JOB_NAME" -n "$NAMESPACE" --for=condition=Complete --timeout="$WAIT_TIMEOUT"; then
    kubectl logs job/"$JOB_NAME" -n "$NAMESPACE" > "${RESULTS_DIR}/loadgen.log" 2>&1 || true
    kubectl describe job "$JOB_NAME" -n "$NAMESPACE" > "${RESULTS_DIR}/job.describe.txt" 2>&1 || true
    kubectl get pods -n "$NAMESPACE" -l job-name="$JOB_NAME" -o wide > "${RESULTS_DIR}/pods.txt" 2>&1 || true
    echo "ERROR: Evaluation job ${JOB_NAME} did not complete within ${WAIT_TIMEOUT}." >&2
    echo "Diagnostics written to ${RESULTS_DIR}" >&2
    exit 1
fi

END_TIME="$(date -Iseconds)"
echo "$END_TIME" > "${RESULTS_DIR}/end_time"
kubectl logs job/"$JOB_NAME" -n "$NAMESPACE" > "${RESULTS_DIR}/loadgen.log" 2>&1 || true

kubectl port-forward -n "$PROM_NAMESPACE" "svc/${PROM_SERVICE}" 9090:9090 > "${RESULTS_DIR}/prometheus-port-forward.log" 2>&1 &
PF_PID="$!"
sleep 3

PROM_URL="http://127.0.0.1:9090"
METRICS=(
    "serverless5gc_function_invocations_total"
    "serverless5gc_function_duration_seconds_sum"
    "serverless5gc_function_duration_seconds_count"
    "serverless5gc_function_duration_seconds_bucket"
    "container_cpu_usage_seconds_total"
    "container_memory_usage_bytes"
)

for METRIC in "${METRICS[@]}"; do
    echo "Querying ${METRIC}"
    curl -s -G "${PROM_URL}/api/v1/query_range" \
        --data-urlencode "query=${METRIC}" \
        --data-urlencode "start=${START_TIME}" \
        --data-urlencode "end=${END_TIME}" \
        --data-urlencode "step=5s" \
        > "${RESULTS_DIR}/${METRIC}.json"
done

cat > "${RESULTS_DIR}/metadata.json" << JSON
{
  "scenario": "${SCENARIO}",
  "target": "serverless-cluster",
  "run": ${RUN},
  "start_time": "${START_TIME}",
  "end_time": "${END_TIME}",
  "ue_count": ${UE_COUNT},
  "registration_rate": ${REG_RATE},
  "pdu_sessions_per_ue": ${PDU_SESSIONS},
  "duration_minutes": ${DURATION}
}
JSON

echo "Results written to ${RESULTS_DIR}"

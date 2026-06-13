#!/bin/bash
# Runs a cold-start storm experiment: starts gNB, then simultaneously deletes all
# function pods AND starts UEs. This ensures the first UE registrations hit the
# Knative service endpoint while function containers are still initializing.
#
# Usage: ./run-coldstart.sh <scenario> [run_number]
#   scenario: low | medium | high | burst
#   run_number: 1 (default)
#
# Environment variables (required):
#   SERVERLESS_IP  - IP of the serverless VM (K3s + Knative)
#   LOADGEN_IP     - IP of the load generator VM (UERANSIM + Prometheus)

set -euo pipefail

SCENARIO="${1:?Usage: $0 <scenario> [run_number]}"
RUN="${2:-1}"

SERVERLESS_IP="${SERVERLESS_IP:?Set SERVERLESS_IP}"
LOADGEN_IP="${LOADGEN_IP:?Set LOADGEN_IP}"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

RESULTS_DIR="${PROJECT_DIR}/eval/results/serverless-sctp-coldstart/${SCENARIO}/run${RUN}"
mkdir -p "$RESULTS_DIR"

UERANSIM_IMAGE="${UERANSIM_IMAGE:-openverso/ueransim:3.2.6}"
SCTP_PROXY_NODEPORT="${SCTP_PROXY_NODEPORT:-31412}"

# Helper functions for SSH
ssh_server() { ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "root@${SERVERLESS_IP}" "$@"; }
ssh_loadgen() { ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "root@${LOADGEN_IP}" "$@"; }
rkube() { ssh_server "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl $*"; }

echo "=== Cold-Start Experiment: ${SCENARIO} run${RUN} ==="
echo "Serverless VM: ${SERVERLESS_IP}"
echo "Loadgen VM:    ${LOADGEN_IP}"
echo "Results:       ${RESULTS_DIR}"

# Parse scenario config
SCENARIO_FILE="${PROJECT_DIR}/eval/scenarios/${SCENARIO}.yaml"
UE_COUNT=$(grep 'count:' "$SCENARIO_FILE" | head -1 | awk '{print $2}')
REG_RATE=$(grep 'registration_rate_per_sec:' "$SCENARIO_FILE" | head -1 | awk '{print $2}')
DURATION=$(grep 'duration_minutes:' "$SCENARIO_FILE" | head -1 | awk '{print $2}')
PDU_SESSIONS=$(grep 'pdu_sessions_per_ue:' "$SCENARIO_FILE" | head -1 | awk '{print $2}')
echo "UEs: ${UE_COUNT}, Rate: ${REG_RATE}/s, Duration: ${DURATION}min, PDU: ${PDU_SESSIONS}/UE"

# ---------------------------------------------------------------------------
# Step 1: Verify all Knative services are ready
# ---------------------------------------------------------------------------
echo ""
echo "Step 1: Verifying Knative services..."
FUNC_COUNT=$(rkube "get ksvc -n default -l app.kubernetes.io/component=procedure-function --no-headers" 2>/dev/null | wc -l)
echo "  ${FUNC_COUNT} procedure services found"
rkube "wait ksvc -n default -l app.kubernetes.io/component=procedure-function --for=condition=Ready --timeout=180s"
READY_COUNT=$(rkube "get ksvc -n default -l app.kubernetes.io/component=procedure-function --no-headers" 2>/dev/null | grep -c 'True' || echo 0)
echo "  ${READY_COUNT}/${FUNC_COUNT} procedure services ready"

# ---------------------------------------------------------------------------
# Step 2: Restart SCTP proxy
# ---------------------------------------------------------------------------
echo ""
echo "Step 2: Restarting SCTP proxy deployment..."
rkube "rollout restart deployment/sctp-proxy -n default"
rkube "rollout status deployment/sctp-proxy -n default --timeout=120s"
echo "  SCTP proxy deployment ready"

# ---------------------------------------------------------------------------
# Step 3: Generate UERANSIM configs and start gNB
# ---------------------------------------------------------------------------
echo ""
echo "Step 3: Setting up gNB..."

GNB_CONFIG="${RESULTS_DIR}/gnb.yaml"
cat > "$GNB_CONFIG" << GNBEOF
mcc: '001'
mnc: '01'
nci: '0x000000010'
idLength: 32
tac: 1
linkIp: ${LOADGEN_IP}
ngapIp: ${LOADGEN_IP}
gtpIp: ${LOADGEN_IP}
amfConfigs:
  - address: ${SERVERLESS_IP}
    port: ${SCTP_PROXY_NODEPORT}
slices:
  - sst: 1
    sd: 0x010203
ignoreStreamIds: true
GNBEOF

UE_CONFIG="${RESULTS_DIR}/ue.yaml"
cat > "$UE_CONFIG" << UEEOF
supi: 'imsi-001010000000001'
mcc: '001'
mnc: '01'
key: '465B5CE8B199B49FAA5F0A2EE238A6BC'
op: 'E8ED289DEBA952E4283B54E88E6183CA'
opType: 'OPC'
amf: '8000'
imei: '356938035643803'
imeiSv: '4370816125816151'
gnbSearchList:
  - ${LOADGEN_IP}
uacAic:
  mps: false
  mcs: false
uacAcc:
  normalClass: 0
  class11: false
  class12: false
  class13: false
  class14: false
  class15: false
sessions:
  - type: 'IPv4'
    apn: 'internet'
    slice:
      sst: 1
      sd: 0x010203
    emergency: false
configured-nssai:
  - sst: 1
    sd: 0x010203
default-nssai:
  - sst: 1
    sd: 0x010203
integrity:
  IA1: true
  IA2: true
  IA3: true
ciphering:
  EA1: true
  EA2: true
  EA3: true
integrityMaxRate:
  uplink: 'full'
  downlink: 'full'
UEEOF

ssh_loadgen "mkdir -p /tmp/s5gc-eval"
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$GNB_CONFIG" "root@${LOADGEN_IP}:/tmp/s5gc-eval/gnb.yaml"
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$UE_CONFIG" "root@${LOADGEN_IP}:/tmp/s5gc-eval/ue.yaml"

ssh_loadgen "docker rm -f s5gc-gnb 2>/dev/null; \
     docker run -d --name s5gc-gnb --network host \
       --entrypoint nr-gnb \
       -v /tmp/s5gc-eval:/config:ro \
       ${UERANSIM_IMAGE} -c /config/gnb.yaml"
sleep 5

if ! ssh_loadgen "docker ps --filter name=s5gc-gnb --format '{{.Status}}'" 2>/dev/null | grep -q "Up"; then
    echo "  ERROR: gNB failed to start"
    ssh_loadgen "docker logs s5gc-gnb" > "${RESULTS_DIR}/gnb.log" 2>&1
    exit 1
fi
echo "  gNB running and connected"

# Record start time
START_TIME=$(date -Iseconds)
echo "$START_TIME" > "${RESULTS_DIR}/start_time"

# ---------------------------------------------------------------------------
# Step 4: COLD-START TRIGGER — delete all Knative function pods AND start UEs simultaneously
# ---------------------------------------------------------------------------
echo ""
echo "Step 4: COLD-START STORM — deleting Knative pods and starting UEs simultaneously..."
DELETE_TS=$(date -Iseconds)
echo "$DELETE_TS" > "${RESULTS_DIR}/coldstart_trigger_time"

# Delete all Knative function pods in background (cold-start trigger)
rkube "delete pods -n default -l app.kubernetes.io/component=procedure-function --grace-period=0 --force" 2>/dev/null &
DELETE_PID=$!

# Immediately start UE batches (don't wait for pod deletion)
BATCH_SIZE=100
BATCH_STAGGER=30
NUM_BATCHES=$(( (UE_COUNT + BATCH_SIZE - 1) / BATCH_SIZE ))

echo "  Pod deletion triggered. Starting ${UE_COUNT} UEs in ${NUM_BATCHES} batches..."

# Clean up any leftover UE containers
ssh_loadgen "for i in \$(seq 1 ${NUM_BATCHES}); do docker rm -f s5gc-ue\${i} 2>/dev/null; done" 2>/dev/null || true

for BATCH in $(seq 1 "$NUM_BATCHES"); do
    BATCH_START=$(( (BATCH - 1) * BATCH_SIZE + 1 ))
    BATCH_COUNT=$BATCH_SIZE
    REMAINING=$((UE_COUNT - (BATCH - 1) * BATCH_SIZE))
    [ "$BATCH_COUNT" -gt "$REMAINING" ] && BATCH_COUNT=$REMAINING
    SUPI=$(printf "imsi-001010%09d" "$BATCH_START")

    BATCH_UE_CONFIG="${RESULTS_DIR}/ue-batch${BATCH}.yaml"
    sed "s/^supi: .*/supi: '${SUPI}'/" "$UE_CONFIG" > "$BATCH_UE_CONFIG"
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        "$BATCH_UE_CONFIG" "root@${LOADGEN_IP}:/tmp/s5gc-eval/ue-batch${BATCH}.yaml"

    echo "  Batch ${BATCH}/${NUM_BATCHES}: ${BATCH_COUNT} UEs from ${SUPI}"
    ssh_loadgen "docker run -d --name s5gc-ue${BATCH} --network host \
           --entrypoint nr-ue \
           -v /tmp/s5gc-eval:/config:ro \
           ${UERANSIM_IMAGE} -c /config/ue-batch${BATCH}.yaml -n ${BATCH_COUNT}" \
        > /dev/null 2>&1

    [ "$BATCH" -lt "$NUM_BATCHES" ] && sleep "$BATCH_STAGGER"
done

# Wait for pod deletion to complete
wait "$DELETE_PID" 2>/dev/null || true

echo "All UEs started. Waiting for ${DURATION} minutes..."
sleep $((DURATION * 60))

# ---------------------------------------------------------------------------
# Step 5: Stop UERANSIM and collect logs
# ---------------------------------------------------------------------------
echo ""
echo "Step 5: Stopping UERANSIM and collecting logs..."
ssh_loadgen "docker logs s5gc-gnb > /tmp/s5gc-eval/gnb-full.log 2>&1; \
     > /tmp/s5gc-eval/ue-full.log; \
     for i in \$(seq 1 ${NUM_BATCHES}); do \
       echo '=== UE Batch '\$i' ===' >> /tmp/s5gc-eval/ue-full.log; \
       docker logs s5gc-ue\${i} >> /tmp/s5gc-eval/ue-full.log 2>&1; \
     done; \
     for i in \$(seq 1 ${NUM_BATCHES}); do docker rm -f s5gc-ue\${i} 2>/dev/null; done; \
     docker rm -f s5gc-gnb 2>/dev/null || true"

scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "root@${LOADGEN_IP}:/tmp/s5gc-eval/gnb-full.log" "${RESULTS_DIR}/gnb.log" 2>/dev/null || true
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "root@${LOADGEN_IP}:/tmp/s5gc-eval/ue-full.log" "${RESULTS_DIR}/ue.log" 2>/dev/null || true

# Record end time
END_TIME=$(date -Iseconds)
echo "$END_TIME" > "${RESULTS_DIR}/end_time"

# ---------------------------------------------------------------------------
# Step 6: Collect Prometheus metrics
# ---------------------------------------------------------------------------
echo ""
echo "Step 6: Collecting Prometheus metrics..."
# Function metrics from Prometheus. Override KNATIVE_PROM if needed.
KNATIVE_PROM="${KNATIVE_PROM:-http://${SERVERLESS_IP}:30175}"
# Node metrics from loadgen Prometheus
NODE_PROM="http://${LOADGEN_IP}:9090"

FUNCTION_METRICS=(
    "serverless5gc_function_invocations_total"
    "serverless5gc_function_duration_seconds_sum"
    "serverless5gc_function_duration_seconds_count"
    "serverless5gc_function_duration_seconds_bucket"
)

NODE_METRICS=(
    "node_cpu_seconds_total"
    "node_memory_MemAvailable_bytes"
)

for METRIC in "${FUNCTION_METRICS[@]}"; do
    echo "  Querying ${METRIC} (Knative functions)..."
    curl -s -G "${KNATIVE_PROM}/api/v1/query_range" \
        --data-urlencode "query=${METRIC}" \
        --data-urlencode "start=${START_TIME}" \
        --data-urlencode "end=${END_TIME}" \
        --data-urlencode "step=5s" \
        > "${RESULTS_DIR}/${METRIC}.json" || echo "  WARNING: Failed to query ${METRIC}"
done

for METRIC in "${NODE_METRICS[@]}"; do
    echo "  Querying ${METRIC} (node)..."
    curl -s -G "${NODE_PROM}/api/v1/query_range" \
        --data-urlencode "query=${METRIC}" \
        --data-urlencode "start=${START_TIME}" \
        --data-urlencode "end=${END_TIME}" \
        --data-urlencode "step=5s" \
        > "${RESULTS_DIR}/${METRIC}.json" || echo "  WARNING: Failed to query ${METRIC}"
done

# Record final pod status
rkube "get pods -n default -l app.kubernetes.io/part-of=serverless5gc --no-headers" 2>/dev/null \
    > "${RESULTS_DIR}/final-pod-status.txt" 2>/dev/null || true

# Save metadata
cat > "${RESULTS_DIR}/metadata.json" << METAEOF
{
    "scenario": "${SCENARIO}",
    "target": "serverless-sctp-coldstart",
    "run": ${RUN},
    "start_time": "${START_TIME}",
    "end_time": "${END_TIME}",
    "ue_count": ${UE_COUNT},
    "registration_rate": ${REG_RATE},
    "pdu_sessions_per_ue": ${PDU_SESSIONS},
    "duration_minutes": ${DURATION},
    "coldstart_trigger_time": "${DELETE_TS}",
    "functions_count": ${FUNC_COUNT},
    "method": "pod-deletion-concurrent-with-ue-start"
}
METAEOF

echo ""
echo "=== Cold-start experiment complete: ${SCENARIO} run${RUN} ==="
echo "Results: ${RESULTS_DIR}"

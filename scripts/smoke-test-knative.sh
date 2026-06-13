#!/usr/bin/env bash
# Runs a basic in-cluster smoke test against Knative procedure services.

set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-cluster.local}"
TEST_IMAGE="${TEST_IMAGE:-curlimages/curl:8.11.1}"
SUPI="${SUPI:-imsi-001010000000001}"

cat << INFO
Running smoke test in namespace ${NAMESPACE}
Using ${TEST_IMAGE}; override TEST_IMAGE if your cluster mirrors images internally.
INFO

kubectl run serverless5gc-smoke \
    -n "$NAMESPACE" \
    --rm \
    -i \
    --restart=Never \
    --image="$TEST_IMAGE" \
    --command -- sh -eu -c "
cat >/tmp/subscriber.json <<'JSON'
{
  \"supi\": \"${SUPI}\",
  \"auth_data\": {
    \"auth_method\": \"5G_AKA\",
    \"k\": \"Rltc6LGZtJ+qXwou4jimvA==\",
    \"opc\": \"6O0oneupUuQoO1TojmGDyg==\",
    \"amf\": \"gAA=\",
    \"sqn\": \"AAAAAAAg\"
  },
  \"access_mobility_data\": {
    \"nssai\": [{\"sst\": 1, \"sd\": \"010203\"}],
    \"default_dnn\": \"internet\"
  },
  \"session_management\": [{
    \"snssai\": {\"sst\": 1, \"sd\": \"010203\"},
    \"dnn\": \"internet\",
    \"qos_ref\": 9
  }]
}
JSON

curl -fsS -X POST http://udr-data-write.${NAMESPACE}.svc.${CLUSTER_DOMAIN} \
  -H 'Content-Type: application/json' \
  --data @/tmp/subscriber.json

curl -fsS -X POST http://amf-auth-initiate.${NAMESPACE}.svc.${CLUSTER_DOMAIN} \
  -H 'Content-Type: application/json' \
  -d '{\"supi\":\"${SUPI}\"}'
"

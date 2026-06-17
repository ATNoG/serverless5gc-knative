#!/usr/bin/env bash
# Patches Knative Serving to use the SAF queue-proxy image.

set -euo pipefail

QUEUE_PROXY_IMAGE="${QUEUE_PROXY_IMAGE:-ghcr.io/atnog/serverless-workflow-firewall/queue:latest}"

kubectl patch configmap config-deployment -n knative-serving \
    --type merge \
    -p "{\"data\":{\"queue-sidecar-image\":\"${QUEUE_PROXY_IMAGE}\"}}"

kubectl patch configmap config-features -n knative-serving \
    --type merge \
    -p '{"data":{"queueproxy.mount-podinfo":"enabled"}}'

echo "Knative Serving is configured to use SAF queue-proxy image: ${QUEUE_PROXY_IMAGE}"

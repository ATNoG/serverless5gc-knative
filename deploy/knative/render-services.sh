#!/usr/bin/env bash
# Renders Knative Service manifests for all procedure functions.

set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
REGISTRY="${REGISTRY:-ghcr.io/atnog/serverless5gc-knative}"
TAG="${TAG:-latest}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-cluster.local}"
CONTAINER_CONCURRENCY="${CONTAINER_CONCURRENCY:-10}"
AUTOSCALE_TARGET="${AUTOSCALE_TARGET:-10}"
MIN_SCALE="${MIN_SCALE:-0}"
MAX_SCALE="${MAX_SCALE:-50}"
FUNCTION_URL_TEMPLATE="${FUNCTION_URL_TEMPLATE:-http://%s.${NAMESPACE}.svc.${CLUSTER_DOMAIN}}"

declare -a FUNCTIONS=(
    "nrf-register|ETCD_ENDPOINT=etcd:2379"
    "nrf-discover|ETCD_ENDPOINT=etcd:2379"
    "nrf-status-notify|ETCD_ENDPOINT=etcd:2379"
    "amf-initial-registration|REDIS_ADDR=redis:6379 ETCD_ENDPOINT=etcd:2379"
    "amf-deregistration|REDIS_ADDR=redis:6379"
    "amf-service-request|REDIS_ADDR=redis:6379"
    "amf-pdu-session-relay|REDIS_ADDR=redis:6379"
    "amf-auth-initiate|REDIS_ADDR=redis:6379"
    "amf-handover|REDIS_ADDR=redis:6379"
    "smf-pdu-session-create|REDIS_ADDR=redis:6379 UPF_PFCP_ADDR=upf:8805 ENABLE_CHARGING=true ENABLE_NSACF=true ENABLE_BSF=true"
    "smf-pdu-session-update|REDIS_ADDR=redis:6379 UPF_PFCP_ADDR=upf:8805"
    "smf-pdu-session-release|REDIS_ADDR=redis:6379 UPF_PFCP_ADDR=upf:8805 ENABLE_CHARGING=true ENABLE_NSACF=true ENABLE_BSF=true"
    "smf-n4-session-setup|REDIS_ADDR=redis:6379 UPF_PFCP_ADDR=upf:8805"
    "udm-generate-auth-data|REDIS_ADDR=redis:6379"
    "udm-get-subscriber-data|REDIS_ADDR=redis:6379"
    "udr-data-read|REDIS_ADDR=redis:6379"
    "udr-data-write|REDIS_ADDR=redis:6379"
    "ausf-authenticate|REDIS_ADDR=redis:6379"
    "pcf-policy-create|REDIS_ADDR=redis:6379"
    "pcf-policy-get|REDIS_ADDR=redis:6379"
    "nssf-slice-select|REDIS_ADDR=redis:6379"
    "nwdaf-analytics-subscribe|REDIS_ADDR=redis:6379"
    "nwdaf-data-collect|REDIS_ADDR=redis:6379"
    "chf-charging-create|REDIS_ADDR=redis:6379 ENABLE_CHARGING=true"
    "chf-charging-update|REDIS_ADDR=redis:6379 ENABLE_CHARGING=true"
    "chf-charging-release|REDIS_ADDR=redis:6379 ENABLE_CHARGING=true"
    "nsacf-slice-availability-check|REDIS_ADDR=redis:6379 ENABLE_NSACF=true"
    "nsacf-update-counters|REDIS_ADDR=redis:6379 ENABLE_NSACF=true"
    "bsf-binding-register|REDIS_ADDR=redis:6379 ENABLE_BSF=true"
    "bsf-binding-discover|REDIS_ADDR=redis:6379 ENABLE_BSF=true"
    "bsf-binding-deregister|REDIS_ADDR=redis:6379 ENABLE_BSF=true"
)

emit_env() {
    local name="$1"
    local value="$2"
    printf '            - name: %s\n' "$name"
    printf '              value: "%s"\n' "$value"
}

emit_service() {
    local name="$1"
    local extra_env="$2"

    cat << YAML
---
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${name}
    app.kubernetes.io/part-of: serverless5gc
    app.kubernetes.io/component: procedure-function
    serverless5gc.knative.dev/events: "enabled"
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: "${MIN_SCALE}"
        autoscaling.knative.dev/max-scale: "${MAX_SCALE}"
        autoscaling.knative.dev/metric: "concurrency"
        autoscaling.knative.dev/target: "${AUTOSCALE_TARGET}"
      labels:
        app.kubernetes.io/name: ${name}
        app.kubernetes.io/part-of: serverless5gc
        app.kubernetes.io/component: procedure-function
        serverless5gc.knative.dev/events: "enabled"
    spec:
      containerConcurrency: ${CONTAINER_CONCURRENCY}
      timeoutSeconds: 60
      containers:
        - image: ${REGISTRY}/${name}:${TAG}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
YAML
    emit_env "FUNCTION_NAME" "$name"
    emit_env "FUNCTION_NAMESPACE" "$NAMESPACE"
    emit_env "CLUSTER_DOMAIN" "$CLUSTER_DOMAIN"
    emit_env "FUNCTION_URL_TEMPLATE" "$FUNCTION_URL_TEMPLATE"
    for pair in $extra_env; do
        emit_env "${pair%%=*}" "${pair#*=}"
    done
}

emit_eventlogger() {
    cat << YAML
---
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: eventlogger
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: eventlogger
    app.kubernetes.io/part-of: serverless5gc
    app.kubernetes.io/component: event-sink
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: "0"
        autoscaling.knative.dev/max-scale: "5"
    spec:
      containerConcurrency: 100
      containers:
        - image: ${REGISTRY}/eventlogger:${TAG}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
YAML
}

for entry in "${FUNCTIONS[@]}"; do
    IFS='|' read -r name envs <<< "$entry"
    emit_service "$name" "$envs"
done

emit_eventlogger

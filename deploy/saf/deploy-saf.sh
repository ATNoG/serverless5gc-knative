#!/usr/bin/env bash
# Deploys Serverless5GC with SAF firewall annotations on every Knative Service.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

NAMESPACE="${NAMESPACE:-default}"
REGISTRY="${REGISTRY:-ghcr.io/atnog/serverless5gc-knative}"
TAG="${TAG:-latest}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-cluster.local}"
KAFKA_BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_SERVERS:-my-cluster-kafka-bootstrap.kafka:9092}"
PATCH_SAF_QUEUE_PROXY="${PATCH_SAF_QUEUE_PROXY:-true}"

if [ "$NAMESPACE" != "default" ]; then
    echo "This deployment currently expects NAMESPACE=default because deploy/k3s manifests are namespace-pinned." >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ "$PATCH_SAF_QUEUE_PROXY" = "true" ]; then
    "${SCRIPT_DIR}/patch-knative-saf.sh"
else
    echo "Skipping Knative queue-proxy patch because PATCH_SAF_QUEUE_PROXY=false"
fi

echo "Rendering SAF-protected Knative Services"
NAMESPACE="$NAMESPACE" \
REGISTRY="$REGISTRY" \
TAG="$TAG" \
CLUSTER_DOMAIN="$CLUSTER_DOMAIN" \
"${SCRIPT_DIR}/render-services.py" > "${TMP_DIR}/services.yaml"

sed "s#serverless5gc-kafka-bootstrap.kafka:9092#${KAFKA_BOOTSTRAP_SERVERS}#g" \
    "${PROJECT_DIR}/deploy/knative/eventing.yaml" > "${TMP_DIR}/eventing.yaml"

echo "Deploying Kubernetes-native infrastructure"
kubectl apply -f "${PROJECT_DIR}/deploy/k3s/redis-deployment.yaml"
kubectl apply -f "${PROJECT_DIR}/deploy/k3s/etcd-deployment.yaml"
kubectl apply -f "${PROJECT_DIR}/deploy/k3s/upf-deployment.yaml"
kubectl apply -f "${PROJECT_DIR}/deploy/k3s/sctp-proxy-deployment.yaml"
kubectl set image deployment/sctp-proxy "sctp-proxy=${REGISTRY}/sctp-proxy:${TAG}" -n "$NAMESPACE"
kubectl set env deployment/sctp-proxy -n "$NAMESPACE" \
    "FUNCTION_NAMESPACE=${NAMESPACE}" \
    "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}" \
    "FUNCTION_URL_TEMPLATE=http://%s.${NAMESPACE}.svc.${CLUSTER_DOMAIN}"

echo "Deploying SAF-protected Knative procedure services"
kubectl apply -f "${TMP_DIR}/services.yaml"

echo "Deploying Knative Eventing resources"
kubectl apply -f "${TMP_DIR}/eventing.yaml"

echo "Waiting for Kubernetes-native deployments"
kubectl rollout status deployment/redis -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/etcd -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/upf -n "$NAMESPACE" --timeout=180s
kubectl rollout status deployment/sctp-proxy -n "$NAMESPACE" --timeout=180s

echo "Waiting for SAF-protected Knative services"
kubectl wait ksvc -n "$NAMESPACE" \
    -l app.kubernetes.io/part-of=serverless5gc \
    --for=condition=Ready \
    --timeout=300s

echo "Waiting for Kafka Broker"
kubectl wait broker/default -n "$NAMESPACE" --for=condition=Ready --timeout=300s

echo "Serverless5GC SAF deployment complete."
echo "Protected service label: serverless5gc.knative.dev/saf-protected=true"

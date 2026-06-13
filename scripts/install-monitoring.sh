#!/usr/bin/env bash
# Installs in-cluster Prometheus for Serverless5GC evaluation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

kubectl apply -f "${PROJECT_DIR}/deploy/monitoring/k8s/prometheus.yaml"
kubectl rollout status deployment/prometheus -n monitoring --timeout=180s

echo "Prometheus is installed."
echo "In-cluster URL: http://prometheus.monitoring.svc.cluster.local:9090"
echo "NodePort URL:   http://<node-ip>:30175"

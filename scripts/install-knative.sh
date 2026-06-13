#!/usr/bin/env bash
# Installs Knative Serving, Kourier networking, Eventing, and the Kafka Broker
# implementation needed by Serverless5GC.

set -euo pipefail

KNATIVE_VERSION="${KNATIVE_VERSION:-knative-v1.22.1}"
KOURIER_VERSION="${KOURIER_VERSION:-${KNATIVE_VERSION}}"
KAFKA_BROKER_VERSION="${KAFKA_BROKER_VERSION:-${KNATIVE_VERSION}}"

echo "Installing Knative Serving ${KNATIVE_VERSION}"
kubectl apply -f "https://github.com/knative/serving/releases/download/${KNATIVE_VERSION}/serving-crds.yaml"
kubectl apply -f "https://github.com/knative/serving/releases/download/${KNATIVE_VERSION}/serving-core.yaml"

echo "Installing Kourier ${KOURIER_VERSION}"
kubectl apply -f "https://github.com/knative-extensions/net-kourier/releases/download/${KOURIER_VERSION}/kourier.yaml"
kubectl patch configmap/config-network \
    --namespace knative-serving \
    --type merge \
    --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'

echo "Installing Knative Eventing ${KNATIVE_VERSION}"
kubectl apply -f "https://github.com/knative/eventing/releases/download/${KNATIVE_VERSION}/eventing-crds.yaml"
kubectl apply -f "https://github.com/knative/eventing/releases/download/${KNATIVE_VERSION}/eventing-core.yaml"

echo "Installing Knative Kafka Broker ${KAFKA_BROKER_VERSION}"
kubectl apply -f "https://github.com/knative-extensions/eventing-kafka-broker/releases/download/${KAFKA_BROKER_VERSION}/eventing-kafka-controller.yaml"
kubectl apply -f "https://github.com/knative-extensions/eventing-kafka-broker/releases/download/${KAFKA_BROKER_VERSION}/eventing-kafka-broker.yaml"
kubectl apply -f "https://github.com/knative-extensions/eventing-kafka-broker/releases/download/${KAFKA_BROKER_VERSION}/eventing-kafka-post-install.yaml"

echo "Waiting for Knative controllers"
kubectl wait --for=condition=Available deployment --all -n knative-serving --timeout=180s
kubectl wait --for=condition=Available deployment --all -n kourier-system --timeout=180s
kubectl wait --for=condition=Available deployment --all -n knative-eventing --timeout=180s

echo "Knative installation complete."
echo "A Kafka cluster is still required. Set KAFKA_BOOTSTRAP_SERVERS when deploying if your bootstrap service is not serverless5gc-kafka-bootstrap.kafka:9092."

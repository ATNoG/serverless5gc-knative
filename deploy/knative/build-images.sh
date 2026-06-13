#!/usr/bin/env bash
# Builds all Serverless5GC images for a Knative deployment.
#
# Usage:
#   deploy/knative/build-images.sh [--push] [--registry ghcr.io/atnog/serverless5gc-knative] [--tag latest]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

REGISTRY="${REGISTRY:-ghcr.io/atnog/serverless5gc-knative}"
TAG="${TAG:-latest}"
PUSH=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --push)
            PUSH=true
            shift
            ;;
        --registry)
            REGISTRY="${2:?--registry requires a value}"
            shift 2
            ;;
        --tag)
            TAG="${2:?--tag requires a value}"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

MODULE="github.com/haidinhtuan/serverless5gc"
ENTRY_DIR="${PROJECT_DIR}/cmd/entry"

cleanup() {
    rm -rf "$ENTRY_DIR"
}
trap cleanup EXIT

declare -a FUNCTIONS=(
    "nrf-register:functions/nrf/register"
    "nrf-discover:functions/nrf/discover"
    "nrf-status-notify:functions/nrf/status-notify"
    "amf-initial-registration:functions/amf/registration"
    "amf-deregistration:functions/amf/deregistration"
    "amf-service-request:functions/amf/service-request"
    "amf-pdu-session-relay:functions/amf/pdu-session-relay"
    "amf-auth-initiate:functions/amf/auth-initiate"
    "amf-handover:functions/amf/handover"
    "smf-pdu-session-create:functions/smf/pdu-session-create"
    "smf-pdu-session-update:functions/smf/pdu-session-update"
    "smf-pdu-session-release:functions/smf/pdu-session-release"
    "smf-n4-session-setup:functions/smf/n4-session-setup"
    "udm-generate-auth-data:functions/udm/generate-auth-data"
    "udm-get-subscriber-data:functions/udm/get-subscriber-data"
    "udr-data-read:functions/udr/data-read"
    "udr-data-write:functions/udr/data-write"
    "ausf-authenticate:functions/ausf/authenticate"
    "pcf-policy-create:functions/pcf/policy-create"
    "pcf-policy-get:functions/pcf/policy-get"
    "nssf-slice-select:functions/nssf/slice-select"
    "nwdaf-analytics-subscribe:functions/nwdaf/analytics-subscribe"
    "nwdaf-data-collect:functions/nwdaf/data-collect"
    "chf-charging-create:functions/chf/charging-create"
    "chf-charging-update:functions/chf/charging-update"
    "chf-charging-release:functions/chf/charging-release"
    "nsacf-slice-availability-check:functions/nsacf/slice-availability-check"
    "nsacf-update-counters:functions/nsacf/update-counters"
    "bsf-binding-register:functions/bsf/binding-register"
    "bsf-binding-discover:functions/bsf/binding-discover"
    "bsf-binding-deregister:functions/bsf/binding-deregister"
)

generate_main() {
    local function_name="$1"
    local func_pkg="$2"
    mkdir -p "$ENTRY_DIR"
    cat > "${ENTRY_DIR}/main.go" << GOEOF
package main

import (
	runtime "${MODULE}/pkg/function"
	function "${MODULE}/${func_pkg}"
)

func main() {
	runtime.Serve("${function_name}", function.Handle)
}
GOEOF
}

build_image() {
    local image_name="$1"
    local dockerfile="$2"
    local image="${REGISTRY}/${image_name}:${TAG}"

    echo "Building ${image}"
    docker build -f "$dockerfile" -t "$image" "$PROJECT_DIR"
    if $PUSH; then
        docker push "$image"
    fi
}

echo "Registry: ${REGISTRY}"
echo "Tag:      ${TAG}"

for entry in "${FUNCTIONS[@]}"; do
    IFS=':' read -r image_name func_pkg <<< "$entry"
    generate_main "$image_name" "$func_pkg"
    build_image "$image_name" "${SCRIPT_DIR}/Dockerfile.function"
done

build_image "sctp-proxy" "${SCRIPT_DIR}/Dockerfile.sctp-proxy"
build_image "eventlogger" "${SCRIPT_DIR}/Dockerfile.eventlogger"

echo "Built ${#FUNCTIONS[@]} function images plus sctp-proxy and eventlogger."

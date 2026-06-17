#!/usr/bin/env python3
"""Render SAF-protected Knative Service manifests for Serverless5GC."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any


FUNCTIONS = [
    ("nrf-register", {"ETCD_ENDPOINT": "etcd:2379"}),
    ("nrf-discover", {"ETCD_ENDPOINT": "etcd:2379"}),
    ("nrf-status-notify", {"ETCD_ENDPOINT": "etcd:2379"}),
    ("amf-initial-registration", {"REDIS_ADDR": "redis:6379", "ETCD_ENDPOINT": "etcd:2379"}),
    ("amf-deregistration", {"REDIS_ADDR": "redis:6379"}),
    ("amf-service-request", {"REDIS_ADDR": "redis:6379"}),
    ("amf-pdu-session-relay", {"REDIS_ADDR": "redis:6379"}),
    ("amf-auth-initiate", {"REDIS_ADDR": "redis:6379"}),
    ("amf-handover", {"REDIS_ADDR": "redis:6379"}),
    ("smf-pdu-session-create", {"REDIS_ADDR": "redis:6379", "UPF_PFCP_ADDR": "upf:8805", "ENABLE_CHARGING": "true", "ENABLE_NSACF": "true", "ENABLE_BSF": "true"}),
    ("smf-pdu-session-update", {"REDIS_ADDR": "redis:6379", "UPF_PFCP_ADDR": "upf:8805"}),
    ("smf-pdu-session-release", {"REDIS_ADDR": "redis:6379", "UPF_PFCP_ADDR": "upf:8805", "ENABLE_CHARGING": "true", "ENABLE_NSACF": "true", "ENABLE_BSF": "true"}),
    ("smf-n4-session-setup", {"REDIS_ADDR": "redis:6379", "UPF_PFCP_ADDR": "upf:8805"}),
    ("udm-generate-auth-data", {"REDIS_ADDR": "redis:6379"}),
    ("udm-get-subscriber-data", {"REDIS_ADDR": "redis:6379"}),
    ("udr-data-read", {"REDIS_ADDR": "redis:6379"}),
    ("udr-data-write", {"REDIS_ADDR": "redis:6379"}),
    ("ausf-authenticate", {"REDIS_ADDR": "redis:6379"}),
    ("pcf-policy-create", {"REDIS_ADDR": "redis:6379"}),
    ("pcf-policy-get", {"REDIS_ADDR": "redis:6379"}),
    ("nssf-slice-select", {"REDIS_ADDR": "redis:6379"}),
    ("nwdaf-analytics-subscribe", {"REDIS_ADDR": "redis:6379"}),
    ("nwdaf-data-collect", {"REDIS_ADDR": "redis:6379"}),
    ("chf-charging-create", {"REDIS_ADDR": "redis:6379", "ENABLE_CHARGING": "true"}),
    ("chf-charging-update", {"REDIS_ADDR": "redis:6379", "ENABLE_CHARGING": "true"}),
    ("chf-charging-release", {"REDIS_ADDR": "redis:6379", "ENABLE_CHARGING": "true"}),
    ("nsacf-slice-availability-check", {"REDIS_ADDR": "redis:6379", "ENABLE_NSACF": "true"}),
    ("nsacf-update-counters", {"REDIS_ADDR": "redis:6379", "ENABLE_NSACF": "true"}),
    ("bsf-binding-register", {"REDIS_ADDR": "redis:6379", "ENABLE_BSF": "true"}),
    ("bsf-binding-discover", {"REDIS_ADDR": "redis:6379", "ENABLE_BSF": "true"}),
    ("bsf-binding-deregister", {"REDIS_ADDR": "redis:6379", "ENABLE_BSF": "true"}),
]


def env(name: str, default: str) -> str:
    return os.environ.get(name, default)


NAMESPACE = env("NAMESPACE", "default")
REGISTRY = env("REGISTRY", "ghcr.io/atnog/serverless5gc-knative")
TAG = env("TAG", "latest")
IMAGE_PULL_POLICY = env("IMAGE_PULL_POLICY", "Always" if TAG == "latest" else "IfNotPresent")
CLUSTER_DOMAIN = env("CLUSTER_DOMAIN", "cluster.local")
CONTAINER_CONCURRENCY = env("CONTAINER_CONCURRENCY", "10")
AUTOSCALE_TARGET = env("AUTOSCALE_TARGET", "10")
MIN_SCALE = env("MIN_SCALE", "0")
MAX_SCALE = env("MAX_SCALE", "50")
FUNCTION_URL_TEMPLATE = env(
    "FUNCTION_URL_TEMPLATE",
    f"http://%s.{NAMESPACE}.svc.{CLUSTER_DOMAIN}",
)


def load_policies() -> dict[str, Any]:
    policy_path = Path(__file__).with_name("policies.json")
    return json.loads(policy_path.read_text())


def compose_policy(catalog: dict[str, Any], name: str) -> dict[str, Any]:
    functions = catalog["functions"]
    if name not in functions:
        raise SystemExit(f"missing SAF policy for {name}")

    spec = functions[name]
    common_name = spec.get("common", "post-json")
    rules = list(catalog["common"].get(common_name, []))

    for profile_name in spec.get("profiles", []):
        profile = catalog["profiles"][profile_name]
        if profile.get("common"):
            rules = list(catalog["common"][profile["common"]])
        rules.extend(profile.get("rules", []))

    rules.extend(spec.get("rules", []))
    if allowed_keys := spec.get("allowed_keys"):
        rules.insert(3, unknown_body_fields_rule(allowed_keys))

    return {
        "request": {
            "default-action": "accept",
            "rules": [
                {"action": rule["action"], "expression": rule["expression"]}
                for rule in rules
            ],
        }
    }


def unknown_body_fields_rule(allowed_keys: list[str]) -> dict[str, str]:
    predicates = " and ".join(f'. != "{key}"' for key in allowed_keys)
    if not predicates:
        predicates = "true"
    return {
        "action": "drop",
        "expression": (
            '.REQUEST.URI.path == "/" '
            'and ((.REQUEST.METHOD | ascii_upcase) == "POST") '
            f'and ((.REQUEST.BODY | keys | map(select({predicates})) | length) > 0)'
        ),
    }


def emit_env(name: str, value: str) -> None:
    print(f"            - name: {name}")
    print(f'              value: "{value}"')


def emit_annotations(policy_json: str, min_scale: str, max_scale: str) -> None:
    print("      annotations:")
    print(f'        autoscaling.knative.dev/min-scale: "{min_scale}"')
    print(f'        autoscaling.knative.dev/max-scale: "{max_scale}"')
    print('        autoscaling.knative.dev/metric: "concurrency"')
    print(f'        autoscaling.knative.dev/target: "{AUTOSCALE_TARGET}"')
    print('        qpoption.knative.dev/firewall-activate: "enable"')
    print(f"        qpoption.knative.dev/firewall-config-rules-json: '{policy_json}'")


def emit_service(catalog: dict[str, Any], name: str, extra_env: dict[str, str]) -> None:
    policy = compose_policy(catalog, name)
    policy_json = json.dumps(policy, separators=(",", ":"))
    print("---")
    print("apiVersion: serving.knative.dev/v1")
    print("kind: Service")
    print("metadata:")
    print(f"  name: {name}")
    print(f"  namespace: {NAMESPACE}")
    print("  labels:")
    print(f"    app.kubernetes.io/name: {name}")
    print("    app.kubernetes.io/part-of: serverless5gc")
    print("    app.kubernetes.io/component: procedure-function")
    print('    serverless5gc.knative.dev/events: "enabled"')
    print("    serverless5gc.knative.dev/saf-protected: \"true\"")
    print("spec:")
    print("  template:")
    print("    metadata:")
    emit_annotations(policy_json, MIN_SCALE, MAX_SCALE)
    print("      labels:")
    print(f"        app.kubernetes.io/name: {name}")
    print("        app.kubernetes.io/part-of: serverless5gc")
    print("        app.kubernetes.io/component: procedure-function")
    print('        serverless5gc.knative.dev/events: "enabled"')
    print('        serverless5gc.knative.dev/saf-protected: "true"')
    print("    spec:")
    print(f"      containerConcurrency: {CONTAINER_CONCURRENCY}")
    print("      timeoutSeconds: 60")
    print("      containers:")
    print(f"        - image: {REGISTRY}/{name}:{TAG}")
    print(f"          imagePullPolicy: {IMAGE_PULL_POLICY}")
    print("          ports:")
    print("            - containerPort: 8080")
    print("          env:")
    emit_env("FUNCTION_NAME", name)
    emit_env("FUNCTION_NAMESPACE", NAMESPACE)
    emit_env("CLUSTER_DOMAIN", CLUSTER_DOMAIN)
    emit_env("FUNCTION_URL_TEMPLATE", FUNCTION_URL_TEMPLATE)
    for key, value in extra_env.items():
        emit_env(key, value)


def emit_eventlogger(catalog: dict[str, Any]) -> None:
    policy_json = json.dumps(compose_policy(catalog, "eventlogger"), separators=(",", ":"))
    print("---")
    print("apiVersion: serving.knative.dev/v1")
    print("kind: Service")
    print("metadata:")
    print("  name: eventlogger")
    print(f"  namespace: {NAMESPACE}")
    print("  labels:")
    print("    app.kubernetes.io/name: eventlogger")
    print("    app.kubernetes.io/part-of: serverless5gc")
    print("    app.kubernetes.io/component: event-sink")
    print('    serverless5gc.knative.dev/saf-protected: "true"')
    print("spec:")
    print("  template:")
    print("    metadata:")
    emit_annotations(policy_json, "0", "5")
    print("      labels:")
    print("        app.kubernetes.io/name: eventlogger")
    print("        app.kubernetes.io/part-of: serverless5gc")
    print("        app.kubernetes.io/component: event-sink")
    print('        serverless5gc.knative.dev/saf-protected: "true"')
    print("    spec:")
    print("      containerConcurrency: 100")
    print("      containers:")
    print(f"        - image: {REGISTRY}/eventlogger:{TAG}")
    print(f"          imagePullPolicy: {IMAGE_PULL_POLICY}")
    print("          ports:")
    print("            - containerPort: 8080")


def main() -> int:
    catalog = load_policies()
    for name, extra_env in FUNCTIONS:
        emit_service(catalog, name, extra_env)
    emit_eventlogger(catalog)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

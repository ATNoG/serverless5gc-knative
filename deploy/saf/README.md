# Serverless5GC With SAF Firewall Protection

This deployment model runs the same Knative-based Serverless5GC control-plane
functions as `deploy/knative`, but every Knative Service is annotated for the
Serverless Application Firewall (SAF) queue-proxy.

The SAF rules are defined in `policies.json` and rendered into:

```text
qpoption.knative.dev/firewall-activate: "enable"
qpoption.knative.dev/firewall-config-rules-json: "<per-service policy>"
```

The Kubernetes-native workloads remain unchanged: Redis, etcd, UPF, and the
SCTP proxy are not SAF-protected because they do not run as Knative Services.

## Prerequisites

- Knative Serving, Knative Eventing, and the Knative Kafka Broker are installed.
- A Kafka cluster is available for the Broker.
- The SAF queue-proxy image is available. Default:
  `ghcr.io/atnog/serverless-workflow-firewall/queue:latest`.
- Serverless5GC images are available. Default:
  `ghcr.io/atnog/serverless5gc-knative/<image>:latest`.

## Deploy

Patch Knative Serving to use the SAF queue-proxy and deploy Serverless5GC:

```bash
deploy/saf/deploy-saf.sh
```

Override images or Kafka bootstrap servers when needed:

```bash
QUEUE_PROXY_IMAGE=ghcr.io/atnog/serverless-workflow-firewall/queue:latest \
REGISTRY=ghcr.io/atnog/serverless5gc-knative \
TAG=latest \
KAFKA_BOOTSTRAP_SERVERS=my-cluster-kafka-bootstrap.kafka:9092 \
deploy/saf/deploy-saf.sh
```

If Knative is already patched to use SAF, skip the patch step:

```bash
PATCH_SAF_QUEUE_PROXY=false deploy/saf/deploy-saf.sh
```

Render the protected Knative Services without applying them:

```bash
deploy/saf/render-services.py > /tmp/serverless5gc-saf-services.yaml
```

## Rule Counts

For paper tables or reproducibility notes, generate the final rule count per
Knative Service from the same `policies.json` catalog:

```bash
deploy/saf/policy-rule-counts.py --output deploy/saf/policy-rule-counts.csv
```

Markdown output is also available:

```bash
deploy/saf/policy-rule-counts.py --format markdown
```

The generated CSV columns are:

- `service`: Knative Service name.
- `common_policy`: shared base policy used by the service.
- `common_rules`: rules inherited from the base policy.
- `allowlist_rules`: strict top-level body allowlist rule count.
- `profile_rules`: reusable domain profile rules, such as SUPI or S-NSSAI.
- `function_rules`: service-specific rules.
- `total_rules`: final number of rendered SAF request rules.
- `profiles`: reusable profiles used by the service.

The current catalog renders 177 request rules across 32 SAF-protected Knative
Services.

## Verify

```bash
kubectl get ksvc -l serverless5gc.knative.dev/saf-protected=true
kubectl get ksvc amf-initial-registration -o jsonpath='{.spec.template.metadata.annotations.qpoption\.knative\.dev/firewall-activate}'
scripts/smoke-test-knative.sh
```

## Measure SAF Flow Overhead

Use the repository-level comparison script to measure representative 5GC flow
latency with and without SAF:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r eval/analysis/requirements.txt

BASELINE_QUEUE_PROXY_IMAGE=<standard-knative-queue-image> \
MODES="baseline SAF" \
FLOW_PROFILE=smf \
ITERATIONS=30 \
WARMUP=5 \
eval/scripts/compare-saf-flow-latency.sh
```

To evaluate the existing AMF-to-SMF relay chain instead:

```bash
BASELINE_QUEUE_PROXY_IMAGE=<standard-knative-queue-image> \
MODES="baseline SAF" \
FLOW_PROFILE=relay \
ITERATIONS=30 \
WARMUP=5 \
eval/scripts/compare-saf-flow-latency.sh
```

The script follows the SAF evaluation model: it runs on a separate machine,
uses `kubectl` only to deploy/wait/read Knative Service URLs, and sends only
the entry request directly to a public Knative route. The representative flow
starts at `smf-pdu-session-create`; that function then calls
`pcf-policy-create`, `nsacf-slice-availability-check`,
`bsf-binding-register`, `chf-charging-create`, and
`nsacf-update-counters` through the in-cluster SBI client. It does not create
an in-cluster Kubernetes Job. The primary latency metric is not client elapsed
time; it is parsed from the Knative queue-proxy log `"latency": "...s"` field,
matching the original SAF latency tests. The external machine must have
kubeapi access and network access to the Knative ingress.

Before each `baseline` or `saf` experiment, the script performs a clean
Serverless5GC reinstall by default. It deletes the existing Serverless5GC
Knative Services, app Knative Eventing objects, Redis, etcd, UPF, SCTP proxy,
and Redis/etcd PVCs, then deploys the requested mode again. This clears
database state between the baseline and SAF measurements without removing the
Knative or Kafka control-plane installations. Use `CLEAN_INSTALL=false` only
when you intentionally want to reuse the existing core installation.

If the Knative `status.url` values are not directly reachable, pass the ingress
IP used by your SAF tests:

```bash
KNATIVE_EXTERNAL_IP=<knative-ingress-ip> \
MODES="current" \
SKIP_DEPLOY=true \
ITERATIONS=10 \
WARMUP=2 \
eval/scripts/compare-saf-flow-latency.sh
```

This uses public URLs of the form:

```text
http://<service>.<namespace>.<knative-ingress-ip>.sslip.io
```

For a custom public domain, pass:

```bash
KNATIVE_URL_TEMPLATE='https://{service}.{namespace}.example.com' \
MODES="current" \
SKIP_DEPLOY=true \
eval/scripts/compare-saf-flow-latency.sh
```

`SKIP_DEPLOY=true` also skips the clean uninstall step. Set
`CLEAN_INSTALL=false` only when you intentionally want to apply a mode over the
current Serverless5GC installation.

The script removes `networking.knative.dev/visibility=cluster-local` from the
entry Knative Service and Route, if present, to ensure
`smf-pdu-session-create` is public. Downstream services are called internally
through Knative service DNS. Outputs are written to
`eval/results/saf-flow-latency/<run-id>/` as diagnostic client trace,
queue-proxy logs, queue-proxy latency CSV summaries, and seaborn PDF charts.
Because the middle SBI calls are synchronous and SMF waits for them before
returning, the orchestrating `smf-pdu-session-create` queue-proxy latency is the
total synchronous flow latency. The graphs label it as
`smf-pdu-session-create (total)`.

With `FLOW_PROFILE=relay`, the measured existing implementation path is:

```text
external client
  -> amf-pdu-session-relay
       -> smf-pdu-session-create
            -> pcf-policy-create
            -> nsacf-slice-availability-check
            -> bsf-binding-register
            -> chf-charging-create
            -> nsacf-update-counters
```

The relay profile pre-provisions subscribers and registers UEs before the
measured log window starts, because the relay handler requires each UE context
to be in `REGISTERED` state. The graphs label the relay entrypoint as
`amf-pdu-session-relay (total)`.

The queue-proxy logs collected for the chained flow are from
`smf-pdu-session-create`, `pcf-policy-create`,
`nsacf-slice-availability-check`, `bsf-binding-register`,
`chf-charging-create`, and `nsacf-update-counters`.

Generated graph files are vector PDFs:

- `charts/step_latency_mean.pdf`: point plot with per-function mean latency and standard error; `smf-pdu-session-create (total)` is the orchestrating flow latency.
- `charts/step_latency_mean_annotated.pdf`: same graph with `mean +/- SE` labels on each point.
- `charts/step_latency_difference.pdf`: point plot with mean `SAF - baseline` latency difference and standard error per function; the `smf-pdu-session-create (total)` point is highlighted with a separate color.
- `charts/step_latency_difference_annotated.pdf`: same graph with horizontal `mean +/- SE` labels on each point.
- `charts/png/*.png`: 300 DPI PNG renders of every generated PDF when using
  `eval/scripts/render-saf-flow-latency-graphs.sh`.

Regenerate summaries, PDF graphs, and PNG renders later from an existing run
without rerunning the tests:

```bash
eval/scripts/render-saf-flow-latency-graphs.sh \
  eval/results/saf-flow-latency/<existing-run-id>
```

The wrapper uses the paper graph layout by default:

```bash
MPLCONFIGDIR=/tmp/matplotlib-serverless5gc \
.venv/bin/python eval/scripts/plot-saf-flow-latency.py \
  eval/results/saf-flow-latency/<existing-run-id> \
  --step-width 13 \
  --step-height 7 \
  --summary-width 10 \
  --summary-height 4 \
  --comparison-width 6.5 \
  --save-pad-inches 0.18
```

It then renders every generated PDF to `charts/png/` using `pdftoppm` at 300
DPI. The graph display labels use uppercase `SAF`; internal mode IDs and
directories remain lowercase for compatibility with the scripts.

`BASELINE_QUEUE_PROXY_IMAGE` is required for a clean comparison when the cluster
has previously been patched to use the SAF queue-proxy; otherwise the baseline
deployment may still use the SAF queue-proxy image.

## Policy Summary

Common root-path rules are composed into the per-service policies:

- `post-json`: root path `/` must be POST and the body must be a JSON object.
- `lookup`: root path `/` may be POST JSON or GET query, used by lookup-style handlers.
- `cloudevent-sink`: root path `/` must be POST and the delivered event data body must be a JSON object.

The rules intentionally apply to `/` only. Runtime paths such as `/healthz` and
`/metrics` are left available for Knative probes and Prometheus scraping.
The SAF queue image used here exposes request headers and URL query parameters
as Go map-backed values. In the tested build, jq expressions that index those
maps can panic during evaluation. The SAF model therefore avoids header
predicates and query-parameter predicates. POST lookup bodies are still
validated by SAF with explicit JSON body rules; GET lookup query values are
validated by the target application handler.
`eventlogger` also returns a small JSON acknowledgement body so the SAF response
hook can process the `202 Accepted` response without seeing a nil response body.
The event logger application treats non-POST requests to `/` as operational
traffic instead of CloudEvents: it returns `200 OK` with a small JSON
`ignored` response and does not log them as audit events. This keeps Knative,
mesh, or manual probe traffic from producing misleading empty `cloudevent`
records. SAF still enforces the event delivery policy for the event sink: real
event delivery to `/` is expected to be POST with a JSON object body.

Every procedure service also declares an `allowed_keys` list in `policies.json`.
The renderer turns that list into a SAF rule that rejects POST requests with
unexpected top-level JSON body parameters. For example, `amf-auth-initiate`
accepts only:

```json
["supi", "serving_network_name"]
```

So a body containing `{"supi":"imsi-001010000000001","debug":true}` is rejected
before it reaches the function. This is implemented with jq allowlist checks
because the current SAF enforcement path validates jq rules reliably; the
schema metadata supported by the SAF language is not used here for request-time
body validation.

Nested objects are still validated by representative semantic rules where the
function logic needs it, such as S-NSSAI `sst`/`sd`, auth method, NF type, event
type, charging type, and counter operation. The strict unknown-parameter rule is
top-level.

| Knative Service | Protected Logic | Representative Rules |
| --- | --- | --- |
| `nrf-register` | NFProfile registration | Reject unknown body keys; known NF type, bounded `nfInstanceId`, bounded `nfServices` list |
| `nrf-discover` | NRF discovery | Reject unknown body keys; POST/GET lookup only, known `target-nf-type` |
| `nrf-status-notify` | NF status update | Reject unknown body keys; bounded `nfInstanceId`, status in `REGISTERED`, `SUSPENDED`, `UNDISCOVERABLE` |
| `amf-initial-registration` | UE registration | Reject unknown body keys; valid SUPI, non-negative RAN UE ID, registration type range, requested NSSAI validation |
| `amf-auth-initiate` | Auth challenge initiation | Reject unknown body keys; valid SUPI, valid serving network name if supplied |
| `amf-deregistration` | UE deregistration | Reject unknown body keys; valid SUPI, bounded deregistration type |
| `amf-service-request` | CM state reconnect | Reject unknown body keys; valid SUPI |
| `amf-pdu-session-relay` | AMF to SMF relay | Reject unknown body keys; valid SUPI, S-NSSAI, and DNN |
| `amf-handover` | N2 handover | Reject unknown body keys; valid SUPI and bounded `target_gnb_id` |
| `smf-pdu-session-create` | PDU session creation | Reject unknown body keys; valid SUPI, S-NSSAI, DNN, PDU session ID, PDU type, bounded AMBR |
| `smf-pdu-session-update` | QoS/PFCP modification | Reject unknown body keys; core-generated `session_id`, QFI range, bounded AMBR updates |
| `smf-pdu-session-release` | PDU session release | Reject unknown body keys; core-generated `session_id` |
| `smf-n4-session-setup` | Direct PFCP setup | Reject unknown body keys; private-looking UE IP, positive SEID, TEID uint32 range |
| `udm-generate-auth-data` | Auth vector generation | Reject unknown body keys; valid SUPI, valid serving network name if supplied |
| `udm-get-subscriber-data` | Subscriber data lookup | Reject unknown body keys; SAF validates SUPI for POST bodies; application validates GET query |
| `udr-data-read` | Subscriber data read | Reject unknown body keys; SAF validates SUPI for POST bodies; application validates GET query |
| `udr-data-write` | Subscriber provisioning | Reject unknown body keys; valid SUPI, auth data object, supported auth method, access/mobility data object |
| `ausf-authenticate` | RES* verification | Reject unknown body keys; valid SUPI, bounded hex `res_star` |
| `pcf-policy-create` | SM policy creation | Reject unknown body keys; valid SUPI, S-NSSAI, and DNN |
| `pcf-policy-get` | Active policy lookup | Reject unknown body keys; SAF validates core-generated `policy_id` for POST bodies; application validates GET query |
| `nssf-slice-select` | Slice selection | Reject unknown body keys; bounded requested NSSAI array, valid SST/SD per item |
| `nwdaf-analytics-subscribe` | Analytics subscription | Reject unknown body keys; known event ID, safe HTTP(S) notification URI |
| `nwdaf-data-collect` | Analytics data ingest | Reject unknown body keys; known collection type, NF ID for NF load, load percentage range |
| `chf-charging-create` | Charging session creation | Reject unknown body keys; valid SUPI, S-NSSAI, DNN, PDU session ID, charging type |
| `chf-charging-update` | Usage update | Reject unknown body keys; core-generated `charging_id`, bounded volume deltas |
| `chf-charging-release` | Charging release/CDR | Reject unknown body keys; core-generated `charging_id` |
| `nsacf-slice-availability-check` | Slice admission check | Reject unknown body keys; valid S-NSSAI, check type in `UE`, `PDU_SESSION` |
| `nsacf-update-counters` | Slice counter update | Reject unknown body keys; valid S-NSSAI, known counter type, known operation |
| `bsf-binding-register` | PCF binding creation | Reject unknown body keys; valid SUPI, S-NSSAI, DNN, PDU session ID, optional PCF address validation |
| `bsf-binding-discover` | Binding discovery | Reject unknown body keys; require UE address or SUPI, validate SUPI if supplied |
| `bsf-binding-deregister` | Binding deletion | Reject unknown body keys; core-generated `binding_id` |
| `eventlogger` | Eventing audit sink | POST-only event delivery with JSON object event data |

# Troubleshooting

Start with `./scripts/verify.sh`; it checks each stage in order and the first FAIL is usually the
cause. Replace `guardrails-demo` below if you changed `NAMESPACE`.

## Operator install plan is Manual and bundles another upgrade

**Symptom:** after subscribing, `oc get installplan` shows an install plan with `APPROVED=false` that
also lists an unrelated operator (for example `servicemeshoperator3`).

**Cause:** OLM resolves all subscriptions in one namespace together. If any subscription there uses
Manual approval, every generated plan is Manual, and the plan includes that subscription's pending
upgrade. Approving it would upgrade the unrelated operator.

**Fix:** do not install into a namespace that holds a Manual subscription (commonly
`openshift-operators`). `manifests/00-operators.yaml` already uses a dedicated namespace and
OperatorGroup per operator. Both operators are AllNamespaces-only, which an OperatorGroup without
`targetNamespaces` provides.

## `NemoGuardrails` CRD not found

TrustyAI is not enabled. Set the TrustyAI component to `Managed` in the DataScienceCluster and wait
for the operator to install the CRD.

## No `traces_span_metrics_calls_total`

Work from the source forward:

```bash
oc logs deploy/nemo-demo -n guardrails-demo -c nemo-guardrails | grep -i -E "otel|trac|export"
oc logs deploy/otel-collector -n guardrails-demo | tail -20
oc get servicemonitor,svc -n guardrails-demo
```

- The NeMo pod must have `OTEL_EXPORTER_OTLP_ENDPOINT` pointing at
  `otel-collector.<ns>.svc.cluster.local:4317` (gRPC) and `tracing.enabled: true` in the ConfigMap.
  After a ConfigMap change, check that the pod was replaced (`oc get pods`). In testing the operator
  rolled it within about 20 seconds; if yours did not, `oc rollout restart deploy/nemo-demo`.
- The `otel-collector` Service must expose a port named `prometheus` (8889). The ServiceMonitor
  selects the Service labelled `app.kubernetes.io/instance: <ns>.otel`.
- In the console, **Observe, Targets** (with "User" source) should show the collector target as Up.
  User workload monitoring must be enabled (see README).

## Raw spanmetrics exist but `guardrails_requests_*` do not

- Recording rules are evaluated by Thanos Ruler and take about a minute after the first scrape.
- Query them through the **Thanos Querier**, not the user-workload Prometheus API.
- Check the rule loaded: `oc get prometheusrule -n guardrails-demo`.

## Dashboard panels are empty

1. Time range covers recent traffic and `traffic-gen` is running.
2. The datasource URL carries the right namespace: `...:9092?namespace=<ns>` in
   `manifests/08-perses-datasource.yaml`. Port 9092 serves user-workload metrics; 9091 is platform
   metrics.
3. Datasource errors:
   - `secret "<name>" attached doesn't exist`: the `secret:` field must be the Perses-internal secret
     named `<datasource-name>-secret`, auto-created from `spec.client.tls`. It is not a Kubernetes
     Secret and no ServiceAccount token is needed; Perses forwards the viewer's own token.
   - `x509: certificate signed by unknown authority`: the `secret:` field is missing, so Perses made the
     upstream call without TLS settings.
4. The viewer needs access to the namespace's metrics. A user with `view` on the namespace works;
   cluster-admin always works.

Check the dashboard CR itself:

```bash
oc get persesdashboard nemo-guardrails-blocked-vs-allowed -n guardrails-demo \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}: {.message}{"\n"}{end}'
```

Perses validates panel specs with CUE. Enum values are lowercase (`legend.position: bottom`,
`mode: list`), and panel references use `#/spec/panels/<id>`, not the CRD path.

## `401`/`403` calling NeMo

The `NemoGuardrails` CR is created with `security.opendatahub.io/enable-auth: 'true'`, so callers
need a bearer token of an identity with the `view` role in the namespace
(`manifests/04-app-rbac.yaml` grants it to `chat-app`). From outside the cluster use
`Authorization: Bearer $(oc whoami -t)` against the Route.

## HTTP 200 with "Could not load the [...] guardrails configuration"

NeMo returns an HTTP 200 chat completion whose content is
`Could not load the ['<config>'] guardrails configuration. An internal error has occurred.` when the
configuration fails to load, for example because `MODEL_API_KEY` is not set in the pod
(`Model API Key environment variable 'MODEL_API_KEY' not set`). Read the pod log for the validation
error: `oc logs deploy/nemo-demo -c nemo-guardrails | grep -B2 -A8 ValidationError`. A copied Secret
with the wrong source name produces exactly this.

## NeMo cannot reach the model (TLS or 401)

- `MODEL_BASE_URL` must end in `/v1`.
- The serving certificate must chain to a CA the pod trusts. The operator mounts the OpenShift
  service CA and the cluster trust bundle; for anything else use `spec.caBundleConfig`.
- `MODEL_API_KEY` is stored in Secret `model-api-key` and mapped to `MODEL_API_KEY` in the pod.
  Rotate it with `oc create secret generic model-api-key ... --dry-run=client -o yaml | oc apply -f -`
  and restart the pod.

## An allowed prompt returns what looks like reasoning text

The model is a reasoning model and the demo caps `max_tokens` at 48. This is not a guardrail
behavior. Raise `max_tokens` in `manifests/06-chat-app.yaml` (`app.py`) or use a non-reasoning model.

## Everything is "blocked" or nothing is

Check the rails in the ConfigMap. Name detection (`PERSON`) is not enabled in this demo; add it under
`entities` if you want it. In testing, phone numbers only reached the configured 0.5 score in
international format (`+1 415 ...`), and `123-45-6789` scored below 0.5 for Presidio (`219-09-9999`
was blocked), which is why the regex rail carries the `NNN-NN-NNNN` pattern.

## After teardown, an empty Perses project remains

Perses keeps a project record for the namespace after the dashboard, datasource and secret are
removed. It is empty and harmless.

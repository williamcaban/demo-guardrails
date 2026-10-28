# How it works

## The telemetry path

```
NeMo Guardrails pod
   | OTLP/gRPC traces  (OTEL_EXPORTER_OTLP_ENDPOINT -> collector :4317)
   v
OpenTelemetryCollector "otel"
   | pipeline traces          -> debug exporter            (swap for Tempo; see "Extending")
   | pipeline traces/metrics  -> filter -> spanmetrics -> prometheus exporter :8889
   v
ServiceMonitor -> User Workload Monitoring (Prometheus)
   v
PrometheusRule "guardrails-request-metrics"  (evaluated by Thanos Ruler)
   | guardrails_requests_total
   | guardrails_requests_blocked_total
   v
Thanos Querier :9092 (?namespace=<ns>)  <-  Perses datasource  <-  Perses dashboard
```

NeMo is configured by three things in `manifests/03-nemo-guardrails.yaml`:

```yaml
# config.yaml (ConfigMap)
tracing:
  enabled: true
  span_format: opentelemetry
  enable_content_capture: false
  adapters:
    - name: OpenTelemetry
```

```yaml
# NemoGuardrails CR spec.env
- {name: OTEL_EXPORTER_OTLP_ENDPOINT, value: "http://otel-collector.<ns>.svc.cluster.local:4317"}
- {name: OTEL_EXPORTER_OTLP_PROTOCOL, value: "grpc"}
- {name: OTEL_SERVICE_NAME,           value: "nemo-guardrails"}
- {name: OTEL_METRICS_EXPORTER,       value: "none"}
```

The RHOAI NeMo server image already bundles the OpenTelemetry SDK, the OTLP exporters and the
FastAPI/httpx instrumentation, so no image changes are needed.

## Span model

Observed on NeMo Guardrails 0.24.0.dev0. For each guarded request NeMo emits:

| Span name | Kind | Attributes that matter |
|---|---|---|
| `guardrails.request` | Server | one per guarded request |
| `guardrails.rail` | Internal | `rail.type` (`input`, `output`, `generation`), `rail.name`, `rail.stop` (`"true"` when this rail blocked the request) |
| `guardrails.action` | Internal | `action.name` (`detect_sensitive_data`, `detect_regex_pattern`, `generate_bot_message`, ...) |
| LLM client span | Client | `gen_ai.request.model`, `gen_ai.usage.*_tokens` (only when the model is called) |

There are also ASGI `http send/receive` spans and spans for `GET /` (kube-probe health checks).
The collector drops everything except `guardrails.request` and `guardrails.rail` from the metrics
pipeline; the full trace still reaches the `debug` exporter.

Two invariants make the counting simple, and both were checked against live traffic:

1. A request stops at the first blocking rail, so a request has **at most one** rail span with
   `rail.stop="true"`. Blocked-request count equals rail-stop count.
2. Every request produces exactly one `guardrails.request` span, so the first input rail's span count
   (`stop="true"` plus `stop="false"`) equals the request count.

## Metrics

`spanmetrics` turns spans into cumulative counters and histograms. With the dimensions configured in
`manifests/02-otel-collector.yaml` the raw series is:

```
traces_span_metrics_calls_total{span_name, span_kind, service_name, rail_name, rail_type, rail_stop}
```

The recording rules in `manifests/05-monitoring.yaml` give it stable, readable names:

| Recorded series | Expression |
|---|---|
| `guardrails_requests_total` | `sum by (service_name) (traces_span_metrics_calls_total{span_name="guardrails.request"})` |
| `guardrails_requests_blocked_total` | `sum by (service_name, rail_type, rail_name) (traces_span_metrics_calls_total{span_name="guardrails.rail", rail_stop="true"})` |

Allowed is derived: `total - blocked`.

Recording rules for user-workload namespaces are evaluated by **Thanos Ruler**, so the recorded
series are visible through the Thanos Querier (and Perses), not through the user-workload
Prometheus API directly.

## Dashboard queries

All panels use `$__rate_interval`, which Perses resolves from the zoom level (the same convention as
Grafana).

| Panel | PromQL |
|---|---|
| Total / Allowed / Blocked (per interval) | `sum(increase(guardrails_requests_total[$__rate_interval]))`, `clamp_min(total - blocked, 0)`, `sum(increase(guardrails_requests_blocked_total[$__rate_interval]))` |
| Block ratio (stat) | `sum(rate(guardrails_requests_blocked_total[$__rate_interval])) / sum(rate(guardrails_requests_total[$__rate_interval]))` |
| Blocked vs allowed (req/s) | `sum(rate(guardrails_requests_blocked_total[$__rate_interval]))` and `clamp_min(sum(rate(guardrails_requests_total[$__rate_interval])) - sum(rate(guardrails_requests_blocked_total[$__rate_interval])), 0)` |
| Absolute counts per interval | `sum(increase(...[$__rate_interval]))` for blocked and allowed, stacked bars |
| Trend | block ratio over `$__rate_interval` against `sum(increase(blocked[1h])) / sum(increase(total[1h]))` |
| Blocked by rail | `sum by (rail_name) (rate(guardrails_requests_blocked_total[$__rate_interval]))` |

`clamp_min(..., 0)` guards against tiny negative values when the two counters are scraped a moment
apart.

## Behaviors that differ from the documentation

| Topic | Documentation | Observed |
|---|---|---|
| Blocked chat completion (inline mode, `/v1/chat/completions`) | `{"status":"blocked", ...}` | HTTP 200 with a canned refusal in `choices[0].message.content` and no blocked flag. |
| Check-only mode, upstream (`/v1/checks`) | Documented as single-turn checks that can transform content | Confirmed live: HTTP 200, `{"status": "passed" or "blocked", "content": ..., "rail": "<rail that blocked>"}`. No model call. Upstream NeMo (`v0.24.0`) has this endpoint. |
| Check-only mode, Red Hat fork (`/v1/guardrail/checks`) | `status` is `success`, `blocked` or `error`, plus `rails_status` | Confirmed live: HTTP 200, `status` is `success` or `blocked` (never `allowed`), per-rail `rails_status`, no model call. Fork-only, per the source. Planned for deprecation in RHOAI 3.6 in favor of `/v1/checks`. |
| Refusal text | n/a | Differs per rail (`I'm sorry, I can't respond to that.` for the regex rail, `I don't know the answer to that.` for Presidio). Not model output: see [Where the refusal text comes from](#where-the-refusal-text-comes-from). |
| Metrics | observability implied | With the Presidio and regex rails used here (the `LLMRails` engine): traces only, and the pod has no `/metrics` endpoint. NeMo does define native counters (`guardrails.requests`, `guardrails.requests.blocked`, ...), but only its newer IORails engine emits them, and IORails supports only content-safety, topic-safety, jailbreak-detection and tool-validation rails. |
| `regex check output` | Flow exists in the regex library | Does nothing unless `rails.config.regex_detection.output.patterns` is set (the action logs `No regex rails configuration found for source: output` and lets everything through). It checks the whole response, so with a reasoning model the thinking text counts too. Verified by `scripts/probe-output.sh`, which sends the trigger prompt five times: whether a run is blocked depends on whether the model's output contains the word, so expect most, not all. |
| Presidio SSN | `US_SSN` entity listed | `123-45-6789` was not blocked; `219-09-9999` was. That is validation, not a miss: in the Presidio source (`us_ssn_recognizer.py`, commit `2523c7b`), `invalidate_result` rejects `123456789` as a published placeholder SSN, along with all-same-digit numbers, zero groups, areas `000`/`666` and mixed delimiters. An earlier version of this demo added an `NNN-NN-NNNN` regex for it; it was redundant and is removed. Built-in recognizers validate; a custom regex checks shape only (see [examples/custom-recognizer.yaml](../examples/custom-recognizer.yaml)). |
| `enable-auth: 'true'` | "requires a bearer token" | Adds a kube-rbac-proxy sidecar (pod 2/2), serves on 443 with service-CA TLS, Route is `reencrypt`. Callers need a token with the `view` role. |

## Where the refusal text comes from

The refusal strings are fixed messages in NeMo's built-in Colang flows, not output of the main model
or of a guardrail prompt. Inspected in the running server image (`nemoguardrails` 0.24.0.dev0, the
`*.v1.co` Colang 1.0 flows used when a config sets no `colang_version`):

| Rail | Flow (under `/app/nemoguardrails/library/`) | Message used | Text |
|---|---|---|---|
| `regex check input` / `output` | `regex/flows.v1.co` | `bot refuse to respond` | `I'm sorry, I can't respond to that.` |
| `detect sensitive data on input` / `output` | `sensitive_data_detection/flows.v1.co` | `bot inform answer unknown` | `I don't know the answer to that.` |

The sensitive-data flows do not define their own refusal. They reuse `bot inform answer unknown`, which
lives in the hallucination library (`hallucination/flows.v1.co`). That is why a PII block reads like
a "no answer" message.

To see it yourself:

```bash
oc exec -n guardrails-demo deploy/nemo-demo -c nemo-guardrails -- \
  grep -rn "I don't know the answer to that\|can't respond to that" /app/nemoguardrails/library --include=*.v1.co
```

The NeMo docs show how to override the `bot refuse to respond` message by redefining it in a Colang file
([self-check rails](https://docs.nvidia.com/nemo/guardrails/latest/configure-guardrails/guardrail-catalog/self-check)).
Whether `bot inform answer unknown` can be overridden the same way from the config's `rails.co` has
not been tested here. The Presidio page only says the bot "will refuse to respond"
([Presidio integration](https://docs.nvidia.com/nemo/guardrails/latest/configure-guardrails/guardrail-catalog/third-party/presidio)).

## Native NeMo metrics (IORails engine)

NeMo 0.24.0.dev0 defines native OpenTelemetry counters, but this demo's rails cannot use them. Verified
on the RHOAI 3.5.1 image with [examples/native-metrics.yaml](../examples/native-metrics.yaml):

| Requirement | Why |
|---|---|
| `NEMO_GUARDRAILS_IORAILS_ENGINE=true` | selects the IORails engine (default is LLMRails) |
| `metrics.enabled: true` in `config.yaml` | defaults to `false` |
| `OTEL_METRICS_EXPORTER=otlp` | the RHOAI docs set `none`; the image runs OpenTelemetry auto-instrumentation, so this env var picks the exporter |
| a collector with a metrics pipeline `otlp -> prometheus` | the demo collector only has `spanmetrics -> prometheus` |
| rails IORails supports | `content safety check input/output`, `topic safety check input`, `jailbreak detection model`, tool call/result validation. Anything else (Presidio, regex, self-check) makes NeMo fall back to LLMRails, which emits no native metrics. |

Series seen at the collector's Prometheus exporter:

| Series | Labels |
|---|---|
| `guardrails_requests_total` (counter) | none |
| `guardrails_requests_blocked_total` (counter) | `rail_type` (value `Input`, capitalized; no `rail_name`) |
| `guardrails_request_duration_seconds` (histogram), `guardrails_requests_active`, `guardrails_nonstream_*_ratio` | |
| `gen_ai_client_operation_duration_seconds`, `gen_ai_client_token_usage` | `gen_ai_*` labels per LLM call |

These are the same names the dashboard queries use, but there is no per-rail label, so the "Blocked by
rail" panel needs the span-derived series. Limits of the test: it used the main reasoning model as the
content-safety classifier, so every request was classified unsafe (4 requests, 4 blocked) and the
allowed path was not exercised; the span-derived pipeline is what this repo's dashboard is built and
validated on.

## Extending

- **Traces backend.** Add a Tempo (or Jaeger) `otlp` exporter to the `traces` pipeline in
  `manifests/02-otel-collector.yaml`; Perses supports Tempo as a datasource and has trace table and Gantt chart panels.
- **Alerts.** Add `PrometheusRule` alerts on `guardrails_requests_blocked_total` /
  `guardrails_requests_total`, for example block ratio above 50% for 10 minutes, or zero traffic.
- **Token cost.** Keep LLM client spans in the filter and add `gen_ai.usage.total_tokens` as a
  `spanmetrics` dimension or a separate count to chart judge/model token use.
- **More rails.** Add HF classifier or `self check input/output` rails in the ConfigMap. They show up
  automatically as new `rail_name` values; no collector change is needed.

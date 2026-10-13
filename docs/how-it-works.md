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
| Blocked chat completion | `{"status":"blocked", ...}` | HTTP 200 with a canned refusal in `choices[0].message.content`. The `status`/`rails_status` shape belongs to `/v1/guardrail/checks`. |
| Refusal text | n/a | Differs per rail (`I'm sorry, I can't respond to that.` for the regex rail, `I don't know the answer to that.` for Presidio). |
| Metrics | observability implied | Traces only. No guardrail metrics from the NeMo pod. |
| Presidio SSN | `US_SSN` entity listed | `123-45-6789` scored below 0.5 and was not blocked; `219-09-9999` was. The regex rail covers the pattern deterministically. |
| `enable-auth: 'true'` | "requires a bearer token" | Adds a kube-rbac-proxy sidecar (pod 2/2), serves on 443 with service-CA TLS, Route is `reencrypt`. Callers need a token with the `view` role. |

## Extending

- **Traces backend.** Add a Tempo (or Jaeger) `otlp` exporter to the `traces` pipeline in
  `manifests/02-otel-collector.yaml`; Perses supports Tempo as a datasource and has trace table and Gantt chart panels.
- **Alerts.** Add `PrometheusRule` alerts on `guardrails_requests_blocked_total` /
  `guardrails_requests_total`, for example block ratio above 50% for 10 minutes, or zero traffic.
- **Token cost.** Keep LLM client spans in the filter and add `gen_ai.usage.total_tokens` as a
  `spanmetrics` dimension or a separate count to chart judge/model token use.
- **More rails.** Add HF classifier or `self check input/output` rails in the ConfigMap. They show up
  automatically as new `rail_name` values; no collector change is needed.

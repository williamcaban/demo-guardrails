#!/usr/bin/env bash
# Deploy the NeMo Guardrails + OTEL + Perses demo.
#
# Required env:
#   MODEL_NAME       model id served by your OpenAI-compatible endpoint (e.g. my-model)
#   MODEL_BASE_URL   endpoint ending in /v1 (e.g. https://my-model-predictor.my-ns.svc.cluster.local:8443/v1)
#   MODEL_API_KEY    bearer token / API key for that endpoint
# Optional env:
#   NAMESPACE        target namespace (default guardrails-demo)
#   OC_CONTEXT       kubeconfig context to use (default: current)
#   SKIP_OPERATORS=1 do not install the OpenTelemetry/COO operators (already present)
#   SKIP_TRAFFIC=1   deploy the app but leave the traffic generator at 0 replicas
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

: "${MODEL_NAME:?set MODEL_NAME}"
: "${MODEL_BASE_URL:?set MODEL_BASE_URL (must end in /v1)}"
: "${MODEL_API_KEY:?set MODEL_API_KEY}"
case "$MODEL_BASE_URL" in */v1) ;; *) die "MODEL_BASE_URL must end in /v1";; esac
export MODEL_NAME MODEL_BASE_URL

log "Cluster: $("${OC[@]}" whoami --show-server)  as  $("${OC[@]}" whoami)"

# ---- Preflight -------------------------------------------------------------
"${OC[@]}" get crd nemoguardrails.trustyai.opendatahub.io >/dev/null 2>&1 \
  || die "NemoGuardrails CRD not found. Enable TrustyAI as Managed in the DataScienceCluster (RHOAI 3.5+)."
"${OC[@]}" get cm cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
  | grep -q 'enableUserWorkload: *true' \
  || warn "User workload monitoring does not look enabled (cluster-monitoring-config). Metrics will not be scraped. See README prerequisites."

# ---- Operators ---------------------------------------------------------------
need_ops=0
for crd in opentelemetrycollectors.opentelemetry.io persesdashboards.perses.dev uiplugins.observability.openshift.io; do
  "${OC[@]}" get crd "$crd" >/dev/null 2>&1 || need_ops=1
done
if [ "${SKIP_OPERATORS:-0}" != 1 ] && [ "$need_ops" = 1 ]; then
  log "Installing OpenTelemetry + Cluster Observability operators (own namespaces)"
  "${OC[@]}" apply -f "$MANIFESTS/00-operators.yaml"
  wait_for 600 Succeeded -n openshift-opentelemetry-operator get csv -o jsonpath='{.items[?(@.spec.displayName=="Red Hat build of OpenTelemetry")].status.phase}' \
    || die "OpenTelemetry operator did not reach Succeeded. Check: oc get installplan,csv -n openshift-opentelemetry-operator"
  wait_for 600 Succeeded -n openshift-cluster-observability-operator get csv -o jsonpath='{.items[?(@.spec.displayName=="Cluster Observability Operator")].status.phase}' \
    || die "COO did not reach Succeeded. Check: oc get installplan,csv -n openshift-cluster-observability-operator"
else
  log "Operators already present (or SKIP_OPERATORS=1)"
fi

# ---- Namespace, secret ---------------------------------------------------------
log "Namespace $NAMESPACE"
apply "$MANIFESTS/01-namespace.yaml"
log "Model API key secret (model-api-key)"
"${OC[@]}" create secret generic model-api-key -n "$NAMESPACE" \
  --from-literal=API_KEY="$MODEL_API_KEY" --dry-run=client -o yaml | "${OC[@]}" apply -f -

# ---- Telemetry + guardrails + app --------------------------------------------
for f in 02-otel-collector 03-nemo-guardrails 04-app-rbac 05-monitoring 06-chat-app; do
  log "Applying $f"; apply "$MANIFESTS/$f.yaml"
done
if [ "${SKIP_TRAFFIC:-0}" = 1 ]; then
  "${OC[@]}" scale deploy/traffic-gen -n "$NAMESPACE" --replicas=0
fi

# ---- Perses --------------------------------------------------------------------
log "Enabling Perses UI plugin (cluster-scoped)"
apply "$MANIFESTS/07-perses-uiplugin.yaml"
wait_for 300 true -n openshift-cluster-observability-operator get pod perses-0 \
  -o jsonpath='{.status.containerStatuses[0].ready}' || warn "perses-0 not ready yet"
log "Perses datasource + dashboard"
apply "$MANIFESTS/08-perses-datasource.yaml"
apply "$MANIFESTS/09-perses-dashboard.yaml"

# ---- Wait + summary -------------------------------------------------------------
log "Waiting for NeMo Guardrails and collector"
wait_for 300 Ready get nemoguardrails nemo-demo -n "$NAMESPACE" -o jsonpath='{.status.phase}' \
  || die "NemoGuardrails not Ready. Check: oc describe nemoguardrails nemo-demo -n $NAMESPACE"
"${OC[@]}" rollout status deploy/otel-collector -n "$NAMESPACE" --timeout=180s
"${OC[@]}" rollout status deploy/chat-app -n "$NAMESPACE" --timeout=180s

cat <<MSG

Done. Metrics appear 1-2 minutes after the first traffic.
  Verify:     NAMESPACE=$NAMESPACE ./scripts/verify.sh
  Probe:      NAMESPACE=$NAMESPACE ./scripts/probe.sh
  Dashboard:  OpenShift console > Observe > Dashboards (Perses) > project "$NAMESPACE"
              > "NeMo Guardrails: blocked vs allowed"
MSG

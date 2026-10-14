# Shared helpers for the demo scripts. Sourced, not executed.
# Requires bash, oc, python3 (verify.sh only), sed.

NAMESPACE="${NAMESPACE:-guardrails-demo}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS="$ROOT/manifests"

# oc wrapper: honours OC_CONTEXT so you can target a non-current kubeconfig context.
OC=(oc)
if [ -n "${OC_CONTEXT:-}" ]; then OC+=(--context "$OC_CONTEXT"); fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

# Model id the main model is served under. This default is the lab model; set MODEL_NAME for any other
# environment (it must match what your endpoint's /v1/models reports).
DEFAULT_MODEL_NAME="qwen3-27b-nvfp4"

# Resolve MODEL_NAME and record where it came from in MODEL_SOURCE. Order: the MODEL_NAME env var, the
# model the deployed NeMo ConfigMap already uses (so a re-run never overwrites a working deployment),
# the chat-app env (MODEL_NAME, or MODEL from older revisions), then DEFAULT_MODEL_NAME.
resolve_model_name() {
  local m=""
  if [ -n "${MODEL_NAME:-}" ]; then MODEL_SOURCE="MODEL_NAME env var"; return 0; fi
  m="$("${OC[@]}" get cm nemo-demo-config -n "$NAMESPACE" -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
       | sed -n 's/^ *model: *//p' | head -1 | tr -d "\"'")" || true
  if [ -n "$m" ]; then MODEL_NAME="$m"; MODEL_SOURCE="deployed NeMo ConfigMap"; return 0; fi
  for n in MODEL_NAME MODEL; do
    m="$("${OC[@]}" get deploy chat-app -n "$NAMESPACE" \
         -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$n\")].value}" 2>/dev/null)" || true
    if [ -n "$m" ]; then MODEL_NAME="$m"; MODEL_SOURCE="chat-app env $n"; return 0; fi
  done
  MODEL_NAME="$DEFAULT_MODEL_NAME"; MODEL_SOURCE="default"
}

# Render a manifest template (only our three placeholders; Perses $__rate_interval is untouched).
render() {
  sed -e "s|\${NAMESPACE}|${NAMESPACE}|g" \
      -e "s|\${MODEL_NAME}|${MODEL_NAME:-}|g" \
      -e "s|\${MODEL_BASE_URL}|${MODEL_BASE_URL:-}|g" "$1"
}
apply() { render "$1" | "${OC[@]}" apply -f -; }
delete() { render "$1" | "${OC[@]}" delete --ignore-not-found -f -; }

# Poll an `oc` command until its output equals a value.
#   wait_for <timeout_s> <expected> get <resource> <name> -n <ns> -o jsonpath=...
wait_for() {
  local timeout="$1" want="$2"; shift 2
  local end=$((SECONDS + timeout)) got=""
  while [ $SECONDS -lt $end ]; do
    got="$("${OC[@]}" "$@" 2>/dev/null || true)"
    [ "$got" = "$want" ] && return 0
    sleep 5
  done
  warn "timed out waiting for: $* (last value: '${got}', wanted '${want}')"
  return 1
}

# Query the Thanos Querier from inside the cluster (needs cluster-admin: exec into the querier pod).
tquery() {
  "${OC[@]}" exec -n openshift-monitoring deploy/thanos-querier -c thanos-query -- \
    curl -s -G localhost:9090/api/v1/query --data-urlencode "query=$1"
}

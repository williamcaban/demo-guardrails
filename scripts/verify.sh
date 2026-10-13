#!/usr/bin/env bash
# Check that every stage of the pipeline is alive and print the current blocked/allowed numbers.
# Needs cluster-admin (it execs into the Thanos Querier pod).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
fail=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }

log "Namespace $NAMESPACE"
phase=$("${OC[@]}" get nemoguardrails nemo-demo -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$phase" = Ready ] && ok "NemoGuardrails nemo-demo is Ready" || bad "NemoGuardrails phase='${phase:-missing}'"
for d in nemo-demo otel-collector chat-app traffic-gen; do
  r=$("${OC[@]}" get deploy "$d" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "${r:-0}" -ge 1 ] 2>/dev/null && ok "deploy/$d ready" || warn "deploy/$d not ready (traffic-gen at 0 is fine if SKIP_TRAFFIC=1)"
done

log "Perses"
for k in persesdatasource/guardrails-thanos persesdashboard/nemo-guardrails-blocked-vs-allowed; do
  s=$("${OC[@]}" get "$k" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
  [ "$s" = True ] && ok "$k Available" || bad "$k Available='${s:-missing}'"
done

log "Metrics (via Thanos Querier)"
num() { tquery "$1" | python3 -c "
import sys,json
try:
    r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 'none')
except Exception: print('error')"; }
raw=$(num "sum(traces_span_metrics_calls_total{namespace=\"$NAMESPACE\",span_name=\"guardrails.request\"})")
tot=$(num "sum(guardrails_requests_total{namespace=\"$NAMESPACE\"})")
blk=$(num "sum(guardrails_requests_blocked_total{namespace=\"$NAMESPACE\"})")
[ "$raw" != none ] && [ "$raw" != error ] && ok "spanmetrics counter present (requests=$raw)" \
  || bad "no traces_span_metrics_calls_total yet: check collector logs and the ServiceMonitor target"
if [ "$tot" != none ] && [ "$tot" != error ]; then ok "recording rules present (total=$tot blocked=${blk})"; \
  else bad "no guardrails_requests_total yet (recording rules take ~1 min after first scrape)"; fi
if [ "$tot" != none ] && [ "$tot" != error ] && [ "$blk" != none ]; then
  python3 - "$tot" "$blk" <<'PY'
import sys
t,b=float(sys.argv[1]),float(sys.argv[2])
print(f"  total={t:.0f} blocked={b:.0f} allowed={t-b:.0f} block_ratio={(b/t if t else 0):.1%}")
PY
fi
[ $fail -eq 0 ] && log "All checks passed" || { warn "Some checks failed"; exit 1; }

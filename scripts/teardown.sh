#!/usr/bin/env bash
# Remove the demo. By default only the namespaced pieces (everything in $NAMESPACE).
#   --operators   also remove the Perses UIPlugin and the OpenTelemetry + COO operators
#                 (cluster-wide: only do this if nothing else on the cluster uses them)
#   -y            do not ask for confirmation
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
ops=0; yes=0
for a in "$@"; do case "$a" in --operators) ops=1;; -y) yes=1;; *) die "unknown arg $a";; esac; done
export MODEL_NAME="${MODEL_NAME:-x}" MODEL_BASE_URL="${MODEL_BASE_URL:-https://x/v1}"

msg="Delete namespace '$NAMESPACE' and everything in it"
[ $ops = 1 ] && msg="$msg, the Perses UIPlugin, and the OpenTelemetry + COO operators"
if [ $yes = 0 ]; then read -r -p "$msg? [y/N] " r; [ "$r" = y ] || [ "$r" = Y ] || die "aborted"; fi

# Delete Perses CRs first so the Perses operator also cleans its internal store.
delete "$MANIFESTS/09-perses-dashboard.yaml" || true
delete "$MANIFESTS/08-perses-datasource.yaml" || true
"${OC[@]}" delete ns "$NAMESPACE" --ignore-not-found --wait=false
if [ $ops = 1 ]; then
  delete "$MANIFESTS/07-perses-uiplugin.yaml" || true
  "${OC[@]}" delete subscription opentelemetry-product -n openshift-opentelemetry-operator --ignore-not-found
  "${OC[@]}" delete subscription cluster-observability-operator -n openshift-cluster-observability-operator --ignore-not-found
  # Select CSVs by name: the namespaces also hold OLM-copied CSVs of other global operators,
  # and the COO label key is truncated at 63 chars, so label selectors are unreliable here.
  for pair in "openshift-opentelemetry-operator:opentelemetry-operator" \
              "openshift-cluster-observability-operator:cluster-observability-operator"; do
    ns="${pair%%:*}"; pkg="${pair##*:}"
    while read -r csv; do
      [ -n "$csv" ] && "${OC[@]}" delete -n "$ns" --ignore-not-found "$csv"
    done < <("${OC[@]}" get csv -n "$ns" -o name 2>/dev/null | grep -E "/${pkg}\.v" || true)
  done
  log "Operators removed. CRDs are left in place (OLM does not delete them); remove manually if desired."
fi
log "Done"

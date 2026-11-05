#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Single end-to-end test for the blog post (OpenShift-native, Kueue path):
#   1. a multi-pod Job that FITS quota  -> Kueue admits it as ONE workload (gang),
#      the 4 pods run on the plain default-scheduler.
#   2. a same-shape Job that EXCEEDS quota -> Kueue leaves it Pending with ZERO
#      pods (all-or-nothing: no stranded half-fleet).
# Prints PASS/FAIL and cleans up.
#
# Prereqs (see the blog "Prerequisites"):
#   - Red Hat build of Kueue installed; Kueue instance CR Available
#     (integrations.frameworks=[BatchJob], workloadManagement.labelPolicy=QueueName)
#   - oc login ... (cluster-admin, to label the namespace + create cluster queues)
#
#   bash test.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-kueue-demo}"
CQ="${CQ:-demo-cq}"

fail(){ echo "FAIL: $*" >&2; cleanup; exit 1; }
cleanup(){
  oc delete job fleet-demo fleet-toobig -n "$NS" --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT    # always clean up, even on interrupt between the applies and the end

echo ">> preflight"
oc whoami >/dev/null 2>&1 || fail "not logged in — run 'oc login' first"
oc get crd workloads.kueue.x-k8s.io >/dev/null 2>&1 || fail "Kueue CRDs missing — install the Kueue operator + instance CR first"

echo ">> 0) ensure namespace is Kueue-managed + queues exist"
oc get ns "$NS" >/dev/null 2>&1 || oc create ns "$NS" >/dev/null
oc label ns "$NS" kueue.openshift.io/managed=true --overwrite >/dev/null   # <-- opt the ns into Kueue
oc apply -f "$HERE/01-kueue-queues.yaml" >/dev/null || fail "could not apply queues"
oc wait --for=condition=Active clusterqueue/"$CQ" --timeout=60s >/dev/null 2>&1 || fail "ClusterQueue $CQ not Active"

echo ">> 1) deploy the fleet that FITS the quota"
cleanup; oc apply -f "$HERE/02-example-job.yaml" >/dev/null || fail "oc apply fleet-demo"

echo ">> 2) Kueue admits ONE workload for the whole fleet"
adm=""
for _ in $(seq 1 24); do
  adm=$(oc get workloads.kueue.x-k8s.io -n "$NS" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.admission.clusterQueue}{"\n"}{end}' 2>/dev/null \
    | awk -v cq="$CQ" '$1 ~ /fleet-demo/ && $2==cq {print $1}')
  [ -n "$adm" ] && break; sleep 5
done
[ -n "$adm" ] || fail "no Workload for fleet-demo admitted by $CQ"
echo "   admitted workload: $adm"

echo ">> 3) all 4 pods Running on the default-scheduler"
r=0
for _ in $(seq 1 24); do
  r=$(oc get pods -n "$NS" -l job-name=fleet-demo --no-headers 2>/dev/null | grep -c Running)
  [ "${r:-0}" -ge 4 ] && break; sleep 5
done
[ "${r:-0}" -ge 4 ] || fail "only ${r:-0}/4 fleet-demo pods Running"
bad=$(oc get pods -n "$NS" -l job-name=fleet-demo \
  -o jsonpath='{range .items[*]}{.spec.schedulerName}{"\n"}{end}' 2>/dev/null | grep -vc '^default-scheduler$')
[ "${bad:-1}" -eq 0 ] || fail "$bad fleet-demo pod(s) not on default-scheduler"
echo "   4/4 pods Running, all on default-scheduler"

echo ">> 4) all-or-nothing: a fleet that EXCEEDS quota gets ZERO pods"
oc apply -f "$HERE/03-gang-gated-job.yaml" >/dev/null || fail "oc apply fleet-toobig"
sleep 8
susp=$(oc get job fleet-toobig -n "$NS" -o jsonpath='{.spec.suspend}' 2>/dev/null)
pods=$(oc get pods -n "$NS" -l job-name=fleet-toobig --no-headers 2>/dev/null | grep -c .)
[ "$susp" = "true" ] || fail "fleet-toobig expected suspend=true, got '$susp'"
[ "${pods:-1}" -eq 0 ] || fail "fleet-toobig should have 0 pods, has ${pods}"
echo "   fleet-toobig: suspend=true, 0 pods (no stranded half-fleet)"

echo
echo "PASS — Kueue gang-admits the fleet as ONE workload on the default-scheduler,"
echo "       and refuses to partially admit a fleet that doesn't fit (all-or-nothing)."
echo ">> cleanup"; cleanup

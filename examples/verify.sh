#!/usr/bin/env bash
# Verify the multi-pod workload is grouped + gang-admitted as a single entity by Kueue.
#   usage: NS=kueue-demo NAME=fleet-demo bash verify.sh
set -uo pipefail
NS="${NS:-kueue-demo}"
NAME="${NAME:-fleet-demo}"
CQ="${CQ:-demo-cq}"

echo "== Kubernetes: the pods that make up the workload =="
oc get pods -n "$NS" -l "job-name=$NAME" \
  -o custom-columns='POD:.metadata.name,SCHEDULER:.spec.schedulerName,STATUS:.status.phase' 2>/dev/null
echo
echo "== Shared gang key on every pod (batch.kubernetes.io/job-name) =="
oc get pods -n "$NS" -l "job-name=$NAME" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  job-name="}{.metadata.labels.batch\.kubernetes\.io/job-name}{"\n"}{end}' 2>/dev/null
echo
echo "== Kueue view: ONE Workload for the whole fleet, and its admission state =="
WL=$(oc get workloads.kueue.x-k8s.io -n "$NS" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -m1 "$NAME")
if [ -n "$WL" ]; then
  oc get workloads.kueue.x-k8s.io "$WL" -n "$NS" \
    -o custom-columns='WORKLOAD:.metadata.name,QUEUE:.spec.queueName,PODSET:.spec.podSets[0].count,ADMITTED-BY:.status.admission.clusterQueue' 2>/dev/null
  oc get workloads.kueue.x-k8s.io "$WL" -n "$NS" \
    -o jsonpath='{range .status.conditions[*]}  {.type}={.status} ({.reason}){"\n"}{end}' 2>/dev/null
else
  echo "  no Kueue Workload for '$NAME' — is the namespace labeled kueue.openshift.io/managed=true"
  echo "  and does the Job carry kueue.x-k8s.io/queue-name?"
fi
echo
echo "== ClusterQueue usage (the single quota line) =="
oc get clusterqueue "$CQ" \
  -o custom-columns='CQ:.metadata.name,ADMITTED:.status.admittedWorkloads,PENDING:.status.pendingWorkloads' 2>/dev/null

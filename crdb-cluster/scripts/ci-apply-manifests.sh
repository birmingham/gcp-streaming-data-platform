#!/usr/bin/env bash
# Runs ON crdb-lab-node-0, copied there over IAP by .github/workflows/apply.yml.
# Waits for the RKE2 cluster to form, applies the CockroachDB manifests in
# dependency order, and waits for cluster-init and the StatefulSet.
#
# Usage: ci-apply-manifests.sh [expected_node_count] [manifest_dir]
set -euo pipefail

EXPECTED_NODES="${1:-5}"
MANIFEST_DIR="${2:-$HOME/crdb_manifests}"
KUBECTL="sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"

echo "Waiting for $EXPECTED_NODES RKE2 nodes to report Ready..."
for i in $(seq 1 60); do
  ready=$($KUBECTL get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l || true)
  echo "  attempt $i/60: ${ready:-0}/$EXPECTED_NODES Ready"
  if [ "${ready:-0}" -ge "$EXPECTED_NODES" ]; then
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "RKE2 cluster did not become Ready in time" >&2
    $KUBECTL get nodes || true
    exit 1
  fi
  sleep 20
done

# Same order as the manual sequence: namespace, storage, StatefulSet, Service, init job
for f in 01-namespace.yaml 05-storage.yaml 03-statefulset.yaml 02-service.yaml 04-cluster-init.yaml; do
  echo "Applying $f"
  $KUBECTL apply -f "$MANIFEST_DIR/$f"
done

echo "Waiting for cluster-init to complete..."
$KUBECTL -n cockroachdb wait --for=condition=complete job/cluster-init --timeout=10m

echo "Waiting for the CockroachDB StatefulSet..."
$KUBECTL -n cockroachdb rollout status statefulset/cockroachdb --timeout=15m

$KUBECTL -n cockroachdb get pods,svc

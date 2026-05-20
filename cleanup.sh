#!/usr/bin/env bash
# ============================================================================
# cleanup.sh -- Tear down the Istio Ingress Gateway Hardening Playground.
#
# Deletes the k3d cluster and all associated resources. The downloaded
# istioctl binary is preserved for reuse on the next run; delete it
# manually if unwanted.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/cluster-vars.sh"

echo "=== Istio Ingress Gateway Hardening Playground :: Cleanup ==="

if k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${CLUSTER_NAME}"; then
    echo "Deleting k3d cluster '${CLUSTER_NAME}'..."
    k3d cluster delete "${CLUSTER_NAME}"
    echo "Cluster deleted."
else
    echo "Cluster '${CLUSTER_NAME}' not found, nothing to clean up."
fi

echo "Done."
echo ""
echo "(The istioctl binary at ${ISTIOCTL} is preserved for reuse. Delete it manually if unwanted.)"

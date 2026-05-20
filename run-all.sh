#!/usr/bin/env bash
# ============================================================================
# run-all.sh -- Orchestrator for the Istio Ingress Gateway Hardening Playground.
#
# Runs all 19 demo scripts in dependency order, batches istiod env-var
# toggles up front (single istiod restart instead of one per demo), and
# prints a PASS/FAIL summary table at the end.
#
# Usage:
#   ./run-all.sh                 # run every demo
#   ./run-all.sh phase1-prevent  # run only one phase directory's demos
#   ./run-all.sh 08c 09a         # run a subset by id
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/cluster-vars.sh"
source "${SCRIPT_DIR}/lib/pass-fail.sh"

ensure_cluster_up || { echo "Cluster not up. Run ./deploy.sh first." >&2; exit 1; }

# The full demo list, in dependency order. Each row: "id|script path|short label".
DEMOS=(
    "01|phase1-prevent/01-validating-webhook.sh|validating-webhook"
    "02|phase1-prevent/02-istioctl-analyze.sh|istioctl-analyze"
    "03|phase1-prevent/03-validating-admission-policy.sh|validating-admission-policy"
    "05a|phase2-limit/05-selector-scoped-gateway-pair-istio.sh|selector-pair (Istio API)"
    "05b|phase2-limit/05-selector-scoped-gateway-pair-gwapi.sh|selector-pair (Gateway API)"
    "06|phase2-limit/06-exportto.sh|exportTo"
    "07|phase2-limit/07-pilot-filter-gateway-cluster-config.sh|PILOT_FILTER_GATEWAY_CLUSTER_CONFIG"
    "08a|phase3-validate/08-traffic-mirroring-istio.sh|mirror VS (HTTP/1.1)"
    "08b|phase3-validate/08-traffic-mirroring-gwapi.sh|mirror HTTPRoute (HTTP/1.1)"
    "08c|phase3-validate/08c-traffic-mirroring-grpc-istio.sh|mirror VS (gRPC)"
    "08d|phase3-validate/08d-traffic-mirroring-grpc-gwapi.sh|mirror GRPCRoute (gRPC)"
    "09a|phase3-validate/09-header-matched-canary-istio.sh|header canary (Istio API)"
    "09b|phase3-validate/09-header-matched-canary-gwapi.sh|header canary (Gateway API)"
    "10|phase4-recover/10-distribution-tracking.sh|distribution tracking + proxy-status"
    "11|phase4-recover/11-experimental-wait-revert.sh|polling + revert"
    "12|phase5-resilience/12-envoy-listener-warming.sh|listener warming"
    "13|phase5-resilience/13-xds-push-connection-cycling.sh|xDS push + connection (HTTP/1.1)"
    "13b|phase5-resilience/13b-xds-push-http2-sustained.sh|xDS push + connection (HTTP/2)"
    "13c|phase5-resilience/13c-xds-push-grpc-long-lived.sh|xDS push + connection (gRPC)"
)

# Optional filter: positional args narrow to ids OR phase directories
SELECTED=()
if [[ $# -eq 0 ]]; then
    SELECTED=("${DEMOS[@]}")
else
    for FILTER in "$@"; do
        for ROW in "${DEMOS[@]}"; do
            IFS='|' read -r ID PATH_REL LABEL <<< "${ROW}"
            if [[ "${ID}" == "${FILTER}" ]] || [[ "${PATH_REL}" == "${FILTER}"/* ]]; then
                SELECTED+=("${ROW}")
            fi
        done
    done
    if [[ ${#SELECTED[@]} -eq 0 ]]; then
        echo "No demos matched filter: $*" >&2
        echo "Available ids:" >&2
        for ROW in "${DEMOS[@]}"; do
            IFS='|' read -r ID PATH_REL LABEL <<< "${ROW}"
            echo "  ${ID}" >&2
        done
        exit 1
    fi
fi

echo "════════════════════════════════════════════════════════════════════════"
echo "  Istio Ingress Gateway Hardening Playground :: run-all.sh"
echo "  ${#SELECTED[@]} demos selected"
echo "════════════════════════════════════════════════════════════════════════"

# ---------------------------------------------------------------------------
# Batched istiod env-var toggles (single restart, instead of per-demo)
# Demos #10 and #11 expect PILOT_ENABLE_CONFIG_DISTRIBUTION_TRACKING + STATUS
# to be on; demo #07 toggles PILOT_FILTER_GATEWAY_CLUSTER_CONFIG itself but
# the per-demo cleanup reverts it, so we don't pre-toggle it here.
# ---------------------------------------------------------------------------
WE_TOGGLED=false
CURRENT_ENV="$(kctl get deployment istiod -n istio-system -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null)"
if ! echo "${CURRENT_ENV}" | grep -q 'PILOT_ENABLE_CONFIG_DISTRIBUTION_TRACKING.*"value":"true"'; then
    echo ""
    echo "Enabling distribution-tracking env vars on istiod (batched)..."
    kctl set env deployment/istiod -n istio-system \
        PILOT_ENABLE_CONFIG_DISTRIBUTION_TRACKING=true PILOT_ENABLE_STATUS=true >/dev/null
    kctl rollout status deployment/istiod -n istio-system --timeout=120s >/dev/null
    WE_TOGGLED=true
    sleep 5
fi

# ---------------------------------------------------------------------------
# Run demos sequentially, capture per-demo result + duration
# ---------------------------------------------------------------------------
RESULTS=()
START_ALL=$(date +%s)
for ROW in "${SELECTED[@]}"; do
    IFS='|' read -r ID PATH_REL LABEL <<< "${ROW}"
    SCRIPT="${SCRIPT_DIR}/${PATH_REL}"
    if [[ ! -x "${SCRIPT}" ]]; then
        RESULTS+=("${ID}|MISSING|0|${LABEL}")
        continue
    fi
    START=$(date +%s)
    "${SCRIPT}" > "/tmp/run-all-${ID}.log" 2>&1
    RC=$?
    DUR=$(($(date +%s) - START))
    if [[ ${RC} -eq 0 ]]; then
        RESULTS+=("${ID}|PASS|${DUR}|${LABEL}")
    else
        RESULTS+=("${ID}|FAIL|${DUR}|${LABEL}")
    fi
    if [[ ${RC} -eq 0 ]]; then
        echo "  ✓ ${ID} PASS (${DUR}s) — ${LABEL}"
    else
        echo "  ✗ ${ID} FAIL (${DUR}s) — ${LABEL}    [log: /tmp/run-all-${ID}.log]"
    fi
done

TOTAL_DUR=$(($(date +%s) - START_ALL))

# ---------------------------------------------------------------------------
# Revert env vars
# ---------------------------------------------------------------------------
if [[ "${WE_TOGGLED}" == "true" ]]; then
    echo ""
    echo "Reverting istiod env vars (run-all.sh enabled them; restoring)..."
    kctl set env deployment/istiod -n istio-system \
        PILOT_ENABLE_CONFIG_DISTRIBUTION_TRACKING- PILOT_ENABLE_STATUS- >/dev/null
    kctl rollout status deployment/istiod -n istio-system --timeout=120s >/dev/null
fi

# ---------------------------------------------------------------------------
# Summary table
# ---------------------------------------------------------------------------
echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "  Summary (${TOTAL_DUR}s total)"
echo "════════════════════════════════════════════════════════════════════════"
PASS_COUNT=0
FAIL_COUNT=0
printf "  %-5s  %-6s  %5s  %s\n" "ID" "STATUS" "TIME" "LABEL"
echo "  ──────────────────────────────────────────────────────────────────"
for R in "${RESULTS[@]}"; do
    IFS='|' read -r ID STATUS DUR LABEL <<< "${R}"
    printf "  %-5s  %-6s  %5ss  %s\n" "${ID}" "${STATUS}" "${DUR}" "${LABEL}"
    [[ "${STATUS}" == "PASS" ]] && PASS_COUNT=$((PASS_COUNT+1))
    [[ "${STATUS}" == "FAIL" ]] && FAIL_COUNT=$((FAIL_COUNT+1))
done
echo "  ──────────────────────────────────────────────────────────────────"
echo "  PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}  Total: ${#RESULTS[@]}"
echo ""
if [[ ${FAIL_COUNT} -gt 0 ]]; then
    echo "Failed demo logs: /tmp/run-all-<id>.log"
    exit 1
fi
exit 0

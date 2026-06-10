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
    "13|phase5-resilience/13-xds-push-track-isolation.sh|xDS push + track isolation (HTTP/1.1)"
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
revert_istiod_env() {
    # Idempotent: kubectl set env VAR- is a no-op if the var isn't set, so
    # firing this on EXIT is safe whether or not we got far enough to toggle.
    if [[ "${WE_TOGGLED}" == "true" ]]; then
        echo ""
        echo "Reverting istiod env vars (run-all.sh enabled them; restoring)..."
        kctl set env deployment/istiod -n "${SYSTEM_NS}" \
            PILOT_ENABLE_CONFIG_DISTRIBUTION_TRACKING- PILOT_ENABLE_STATUS- >/dev/null 2>&1 || true
        kctl rollout status deployment/istiod -n "${SYSTEM_NS}" --timeout=120s >/dev/null 2>&1 || true
        WE_TOGGLED=false
    fi
}
trap revert_istiod_env EXIT INT TERM

CURRENT_ENV="$(kctl get deployment istiod -n "${SYSTEM_NS}" -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null)"
if ! echo "${CURRENT_ENV}" | grep -q 'PILOT_ENABLE_CONFIG_DISTRIBUTION_TRACKING.*"value":"true"'; then
    echo ""
    echo "Enabling distribution-tracking env vars on istiod (batched)..."
    kctl set env deployment/istiod -n "${SYSTEM_NS}" \
        PILOT_ENABLE_CONFIG_DISTRIBUTION_TRACKING=true PILOT_ENABLE_STATUS=true >/dev/null
    kctl rollout status deployment/istiod -n "${SYSTEM_NS}" --timeout=120s >/dev/null
    WE_TOGGLED=true
    sleep 5
fi

# ---------------------------------------------------------------------------
# Run demos sequentially, capture per-demo result + duration
#
# DEMO_TIMEOUT (default 300s) bounds each demo. A stuck demo (e.g., a port-
# forward that never establishes, a kubectl exec that hangs) becomes a FAIL
# with exit 124 instead of wedging the orchestrator. Override per run with
# DEMO_TIMEOUT=600 ./run-all.sh ...
# ---------------------------------------------------------------------------
DEMO_TIMEOUT="${DEMO_TIMEOUT:-300}"
# Resolve a timeout binary (gtimeout on macOS via coreutils; timeout on Linux).
# We store it as a plain string, not an array — empty array expansion under
# `set -u` errors on macOS default bash 3.2.
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
else
    echo "  ! no timeout(1) found (install GNU coreutils for gtimeout on macOS); demos will run unbounded"
    TIMEOUT_BIN=""
fi

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
    if [[ -n "${TIMEOUT_BIN}" ]]; then
        "${TIMEOUT_BIN}" "${DEMO_TIMEOUT}" "${SCRIPT}" > "/tmp/run-all-${ID}.log" 2>&1
    else
        "${SCRIPT}" > "/tmp/run-all-${ID}.log" 2>&1
    fi
    RC=$?
    DUR=$(($(date +%s) - START))
    if [[ ${RC} -eq 0 ]]; then
        RESULTS+=("${ID}|PASS|${DUR}|${LABEL}")
        echo "  ✓ ${ID} PASS (${DUR}s) — ${LABEL}"
    elif [[ ${RC} -eq 124 ]]; then
        RESULTS+=("${ID}|TIMEOUT|${DUR}|${LABEL}")
        echo "  ⏱ ${ID} TIMEOUT (${DUR}s, killed after ${DEMO_TIMEOUT}s) — ${LABEL}    [log: /tmp/run-all-${ID}.log]"
    else
        RESULTS+=("${ID}|FAIL|${DUR}|${LABEL}")
        echo "  ✗ ${ID} FAIL (${DUR}s) — ${LABEL}    [log: /tmp/run-all-${ID}.log]"
    fi
done

TOTAL_DUR=$(($(date +%s) - START_ALL))

# ---------------------------------------------------------------------------
# Revert env vars (the EXIT/INT/TERM trap above handles interrupts too;
# calling explicitly here keeps the revert in the normal flow so the rollout
# wait completes before the summary table prints).
# ---------------------------------------------------------------------------
revert_istiod_env

# ---------------------------------------------------------------------------
# Summary table
# ---------------------------------------------------------------------------
echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "  Summary (${TOTAL_DUR}s total)"
echo "════════════════════════════════════════════════════════════════════════"
PASS_COUNT=0
FAIL_COUNT=0
TIMEOUT_COUNT=0
printf "  %-5s  %-7s  %5s  %s\n" "ID" "STATUS" "TIME" "LABEL"
echo "  ──────────────────────────────────────────────────────────────────"
for R in "${RESULTS[@]}"; do
    IFS='|' read -r ID STATUS DUR LABEL <<< "${R}"
    printf "  %-5s  %-7s  %5ss  %s\n" "${ID}" "${STATUS}" "${DUR}" "${LABEL}"
    case "${STATUS}" in
        PASS)    PASS_COUNT=$((PASS_COUNT+1)) ;;
        FAIL)    FAIL_COUNT=$((FAIL_COUNT+1)) ;;
        TIMEOUT) TIMEOUT_COUNT=$((TIMEOUT_COUNT+1)) ;;
    esac
done
echo "  ──────────────────────────────────────────────────────────────────"
echo "  PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}  TIMEOUT: ${TIMEOUT_COUNT}  Total: ${#RESULTS[@]}"
echo ""
if [[ $((FAIL_COUNT + TIMEOUT_COUNT)) -gt 0 ]]; then
    echo "Non-passing demo logs: /tmp/run-all-<id>.log"
    exit 1
fi
exit 0

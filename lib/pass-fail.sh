#!/usr/bin/env bash
# ============================================================================
# lib/pass-fail.sh -- Shared helpers for demo scripts.
#
# Two responsibilities:
#   1. Demo contract — `demo_start` / `demo_step` / `demo_info` /
#      `demo_assert_pass` / `demo_assert_fail` / `demo_end` / `demo_assert_status_was`.
#      Each demo sources this file and uses these helpers to produce
#      consistent, parseable output. run-all.sh parses the same output to
#      build its summary table, so don't rename them or alter the prefixes
#      without updating the orchestrator.
#   2. Shared utilities used by multiple demos:
#        start_port_forward   — backgrounds kubectl port-forward correctly
#                                (echoes the real kubectl PID)
#        wait_until_synced    — polls istioctl proxy-status until SYNCED
#                                (replacement for removed `experimental wait`)
#        envoy_upstream_rq    — sums per-cluster upstream_rq_completed across
#                                gateway pods and both Envoy stat buckets
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/pass-fail.sh"
#   demo_start "01" "validating-webhook" "Webhook rejects per-object schema errors"
#   ... do work ...
#   demo_assert_pass "Webhook rejected the malformed VirtualService"   # or
#   demo_assert_fail "Webhook unexpectedly accepted the malformed VS"
#   demo_end
# ============================================================================

# Color codes (no-op if NO_COLOR is set or stdout isn't a tty)
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    _GREEN='\033[0;32m'
    _RED='\033[0;31m'
    _YELLOW='\033[0;33m'
    _BLUE='\033[0;34m'
    _BOLD='\033[1m'
    _RESET='\033[0m'
else
    _GREEN='' _RED='' _YELLOW='' _BLUE='' _BOLD='' _RESET=''
fi

# Demo-scoped state
_DEMO_ID=""
_DEMO_NAME=""
_DEMO_HYPOTHESIS=""
_DEMO_PASS_COUNT=0
_DEMO_FAIL_COUNT=0
_DEMO_START_TS=0

demo_start() {
    _DEMO_ID="$1"
    _DEMO_NAME="$2"
    _DEMO_HYPOTHESIS="$3"
    _DEMO_PASS_COUNT=0
    _DEMO_FAIL_COUNT=0
    _DEMO_START_TS="$(date +%s)"
    echo ""
    echo -e "${_BOLD}${_BLUE}━━━ Demo #${_DEMO_ID}: ${_DEMO_NAME} ━━━${_RESET}"
    echo -e "${_BLUE}Hypothesis:${_RESET} ${_DEMO_HYPOTHESIS}"
    echo ""
}

demo_step() {
    echo -e "${_YELLOW}»${_RESET} $*"
}

demo_info() {
    echo -e "  ${_BLUE}•${_RESET} $*"
}

demo_assert_pass() {
    _DEMO_PASS_COUNT=$((_DEMO_PASS_COUNT + 1))
    echo -e "  ${_GREEN}✓ PASS:${_RESET} $*"
}

demo_assert_fail() {
    _DEMO_FAIL_COUNT=$((_DEMO_FAIL_COUNT + 1))
    echo -e "  ${_RED}✗ FAIL:${_RESET} $*" >&2
}

demo_end() {
    local elapsed=$(( $(date +%s) - _DEMO_START_TS ))
    local total=$((_DEMO_PASS_COUNT + _DEMO_FAIL_COUNT))
    echo ""
    if [[ "${_DEMO_FAIL_COUNT}" -eq 0 ]] && [[ "${_DEMO_PASS_COUNT}" -gt 0 ]]; then
        echo -e "${_GREEN}${_BOLD}━━━ Demo #${_DEMO_ID} OVERALL: PASS${_RESET}${_GREEN} (${_DEMO_PASS_COUNT}/${total} assertions, ${elapsed}s) ━━━${_RESET}"
        return 0
    elif [[ "${_DEMO_FAIL_COUNT}" -gt 0 ]]; then
        echo -e "${_RED}${_BOLD}━━━ Demo #${_DEMO_ID} OVERALL: FAIL${_RESET}${_RED} (${_DEMO_PASS_COUNT} pass / ${_DEMO_FAIL_COUNT} fail / ${total} assertions, ${elapsed}s) ━━━${_RESET}"
        return 1
    else
        echo -e "${_YELLOW}${_BOLD}━━━ Demo #${_DEMO_ID} OVERALL: NO ASSERTIONS${_RESET}${_YELLOW} (script bug) ━━━${_RESET}"
        return 2
    fi
}

# ----------------------------------------------------------------------------
# start_port_forward NS SERVICE LOCAL_PORT:REMOTE_PORT
#
# Backgrounds `kubectl port-forward` and echoes the PID to stdout. Verifies
# the process is alive after a short settle delay; if it died, returns 1.
#
# Why this exists: backgrounding the `kctl` *function* wrapper (`kctl ... &`)
# captures the subshell PID, not kubectl's — so a trap that does
# `kill ${PF_PID}` reaps the wrapper and leaves the real kubectl orphaned,
# holding the port. Calling `kubectl` directly fixes that. Every demo needs
# the same five lines, so we centralise.
#
# Caller is responsible for the trap that kills the returned PID.
#
# Usage:
#   PF_PID=$(start_port_forward istio-system "svc/ingress-gw-canary" 18681:80) \
#     || { demo_assert_fail "port-forward failed"; demo_end; exit $?; }
# ----------------------------------------------------------------------------
start_port_forward() {
    local ns=$1
    local target=$2
    local port_spec=$3
    kubectl --context "${CONTEXT}" port-forward -n "${ns}" "${target}" "${port_spec}" >/dev/null 2>&1 &
    local pid=$!
    sleep 2
    if ! kill -0 "${pid}" 2>/dev/null; then
        echo "ERROR: port-forward to ${target} died (PID ${pid})" >&2
        return 1
    fi
    echo "${pid}"
}
export -f start_port_forward

# ----------------------------------------------------------------------------
# wait_until_synced [LABEL_SELECTOR] [TIMEOUT_SECS]
#
# Polls `istioctl proxy-status` until every matching gateway pod reports
# SYNCED (no STALE / NOT SENT in any xDS-type column). This is the
# documented replacement for `istioctl experimental wait --for=distribution`
# which was removed in Istio 1.27.
#
# Defaults:
#   LABEL_SELECTOR — "ingress-gw-${TRACK_CANARY}" substring (matches the
#                    proxy-status row's pod-name column)
#   TIMEOUT_SECS   — 30
#
# Returns 0 on SYNCED, 1 on timeout.
# ----------------------------------------------------------------------------
wait_until_synced() {
    local match=${1:-"ingress-gw-${TRACK_CANARY}"}
    local timeout=${2:-30}
    local start=$(date +%s)
    while [[ $(($(date +%s) - start)) -lt ${timeout} ]]; do
        local ps_output
        ps_output="$("${ISTIOCTL}" --context "${CONTEXT}" proxy-status 2>/dev/null | grep "${match}" || true)"
        # When the selector matches no rows, proxy-status returns empty. Skip
        # this tick — counting "echo ''" as 1 line via wc would otherwise
        # report SYNCED with zero pods.
        if [[ -z "${ps_output}" ]]; then
            sleep 1
            continue
        fi
        local stale_count pod_count
        stale_count="$(echo "${ps_output}" | grep -cE "STALE|NOT SENT" || true)"
        pod_count="$(echo "${ps_output}" | grep -c .)"
        if [[ "${stale_count}" -eq 0 ]] && [[ "${pod_count}" -ge 1 ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}
export -f wait_until_synced

# ----------------------------------------------------------------------------
# envoy_upstream_rq SERVICE_NAME SERVICE_NS PORT GW_POD_NS GW_PODS_STR
#
# Reads Envoy's per-cluster `upstream_rq_completed` counter for a target
# Service across every gateway pod in GW_PODS_STR (space-separated), summed
# across both `.external.` (downstream-originated) and `.internal.`
# (Envoy-synthesized — e.g. mirror traffic) stat buckets. Without summing
# both buckets, mirror destinations show 0 even when actively receiving.
#
# Why this is awk index() and not a regex: the Envoy stat-extraction format
# uses `;.` as a tag prefix, plus `|` for cluster name segments — both of
# which are awk regex metacharacters. Substring matching via index() is
# simpler and faster than escaping.
#
# Echoes the integer total.
#
# Example:
#   PRE=$(envoy_upstream_rq grpcbin "${APPS_NS}" 9000 "${SYSTEM_NS}" "${CANARY_GW_PODS}")
# ----------------------------------------------------------------------------
envoy_upstream_rq() {
    local svc=$1 svc_ns=$2 port=$3 gw_ns=$4 gw_pods=$5
    local total=0 v pod bucket
    for pod in ${gw_pods}; do
        for bucket in external internal; do
            v=$(kctl exec -n "${gw_ns}" "${pod}" -c istio-proxy -- \
                    pilot-agent request GET stats 2>/dev/null \
                | awk -F': ' -v key="cluster.outbound|${port}||${svc}.${svc_ns}.svc.cluster.local;.${bucket}.upstream_rq_completed" \
                    'index($0, key) > 0 {print $2; exit}' \
                | tr -d ' ')
            total=$((total + ${v:-0}))
        done
    done
    echo "${total}"
}
export -f envoy_upstream_rq

# Convenience: assert that the previous command exited with the expected status.
# Usage:
#   kubectl apply -f bad.yaml; demo_assert_status_was $? "1+" "Apply should have failed"
demo_assert_status_was() {
    local actual=$1
    local expected_pattern=$2  # "0", "1+", "non-zero", a specific number
    local message=$3
    case "${expected_pattern}" in
        0)
            [[ "${actual}" -eq 0 ]] && demo_assert_pass "${message} (exit=${actual})" || demo_assert_fail "${message} (exit=${actual}, expected 0)"
            ;;
        "1+"|"non-zero")
            [[ "${actual}" -ne 0 ]] && demo_assert_pass "${message} (exit=${actual})" || demo_assert_fail "${message} (exit=${actual}, expected non-zero)"
            ;;
        *)
            [[ "${actual}" -eq "${expected_pattern}" ]] && demo_assert_pass "${message} (exit=${actual})" || demo_assert_fail "${message} (exit=${actual}, expected ${expected_pattern})"
            ;;
    esac
}
export -f demo_start demo_step demo_info demo_assert_pass demo_assert_fail demo_end demo_assert_status_was

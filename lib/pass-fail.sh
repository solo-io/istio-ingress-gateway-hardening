#!/usr/bin/env bash
# ============================================================================
# lib/pass-fail.sh -- Shared PASS/FAIL output helpers for demo scripts.
#
# Each demo sources this file and uses the helpers to produce consistent,
# parseable output. run-all.sh parses the same output to build its summary
# table.
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

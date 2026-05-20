#!/usr/bin/env bash
# ============================================================================
# Demo #11 — Polling proxy-status as a CD-pipeline gate (forward + revert)
# ============================================================================
#
# HYPOTHESIS
#   A CD pipeline can gate on `istioctl proxy-status` showing SYNCED across
#   all matching proxies before considering an apply (or a revert) complete.
#   The forward path applies a candidate VS-v2; the revert path re-applies
#   the prior VS-v1. In each case, polling proxy-status until SYNCED gives
#   the same gate behavior the (now-removed) `istioctl experimental wait`
#   command used to provide.
#
# CRITICAL ITERATION FINDING (changes PLAN.md FR signals)
#   `istioctl experimental wait --for=distribution` was REMOVED in Istio 1.27.
#   It is not present under `istioctl wait`, `istioctl experimental wait`,
#   or any other top-level command in 1.27.8 (`istioctl --help` confirms).
#   PLAN.md referenced this command as a CD-pipeline gate; this demo now
#   demonstrates the replacement pattern (polling proxy-status) and surfaces
#   the removal as a STRONG product-improvement signal: a CD-critical
#   command was dropped without a documented replacement.
#
# SETUP / VERIFICATION / PASS
#   - Apply VS-v1, poll proxy-status until SYNCED, verify routing to v1
#   - Apply VS-v2 (overwrites v1), poll until SYNCED, verify routing to v2
#   - Apply VS-v1 again ("git revert"), poll until SYNCED, verify routing
#     back to v1
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "11" "proxy-status-poll-revert" \
  "Polling proxy-status gates forward AND revert paths (replaces removed 'experimental wait')"

TMPDIR_DEMO="$(mktemp -d)"
PF_PID=""
WE_TOGGLED_ENV_VARS=false
cleanup_demo() {
    rm -rf "${TMPDIR_DEMO}"
    [[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true
    kctl delete virtualservice demo11-vs -n apps --ignore-not-found 2>/dev/null
    kctl delete gateway demo11-canary-gw -n istio-system --ignore-not-found 2>/dev/null
    if [[ "${WE_TOGGLED_ENV_VARS}" == "true" ]]; then
        echo "  • Reverting istiod env vars..."
        kctl set env deployment/istiod -n istio-system \
            PILOT_ENABLE_CONFIG_DISTRIBUTION_TRACKING- PILOT_ENABLE_STATUS- 2>/dev/null
        kctl rollout status deployment/istiod -n istio-system --timeout=120s 2>/dev/null
    fi
}
trap cleanup_demo EXIT

# ---------------------------------------------------------------------------
# Step 0: ensure tracking env vars are on (experimental wait depends on them)
# ---------------------------------------------------------------------------
demo_step "Ensuring distribution tracking env vars are on"
CURRENT_ENV="$(kctl get deployment istiod -n istio-system -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null)"
if ! echo "${CURRENT_ENV}" | grep -q 'PILOT_ENABLE_CONFIG_DISTRIBUTION_TRACKING.*"value":"true"'; then
    demo_info "Toggling istiod env vars (will revert in cleanup)"
    kctl set env deployment/istiod -n istio-system \
        PILOT_ENABLE_CONFIG_DISTRIBUTION_TRACKING=true PILOT_ENABLE_STATUS=true >/dev/null
    kctl rollout status deployment/istiod -n istio-system --timeout=120s >/dev/null
    WE_TOGGLED_ENV_VARS=true
    sleep 5
else
    demo_info "Tracking env vars already on"
fi

# ---------------------------------------------------------------------------
# Step 1: apply the canary-gateway resource (stable across the demo)
# ---------------------------------------------------------------------------
demo_step "Applying demo11-canary-gw (stable; only VS will change)"
cat > "${TMPDIR_DEMO}/gateway.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: demo11-canary-gw
  namespace: istio-system
spec:
  selector:
    app: ${GATEWAY_APP_LABEL}
    ${TRACK_LABEL_KEY}: ${TRACK_CANARY}
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts: ["demo11.example.com"]
EOF
kctl apply -f "${TMPDIR_DEMO}/gateway.yaml" >/dev/null

# Render two VS variants for v1 and v2
for VARIANT in v1 v2; do
    cat > "${TMPDIR_DEMO}/vs-${VARIANT}.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: demo11-vs
  namespace: apps
spec:
  hosts: ["demo11.example.com"]
  gateways: ["istio-system/demo11-canary-gw"]
  http:
  - route:
    - destination:
        host: httpbin-${VARIANT}.apps.svc.cluster.local
        port:
          number: 8000
EOF
done

# port-forward to canary gateway for traffic verification
LOCAL_PORT=18793
# Use `kubectl` directly (not the kctl function wrapper) so $! captures the
# real kubectl PID. Backgrounding a bash function returns the subshell PID
# instead, and the cleanup trap's `kill ${PF_PID}` would kill the wrapper
# but leave the kubectl child orphaned, holding the port.
kubectl --context "${CONTEXT}" port-forward -n istio-system \
    "svc/${GATEWAY_APP_LABEL}-${TRACK_CANARY}" "${LOCAL_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
sleep 2

V1_POD="$(kctl get pod -n apps -l app=httpbin,version=v1 -o jsonpath='{.items[0].metadata.name}')"
V2_POD="$(kctl get pod -n apps -l app=httpbin,version=v2 -o jsonpath='{.items[0].metadata.name}')"
_logcount() { kctl logs -n apps "$1" 2>/dev/null | wc -l | tr -d ' '; }

# Helper: poll proxy-status until all canary gateway pods report fully SYNCED
# (the documented CD-gate replacement for the removed 'experimental wait').
# Returns 0 on SYNCED, 1 on timeout.
wait_until_synced() {
    local timeout=${1:-30}
    local start=$(date +%s)
    while [[ $(($(date +%s) - start)) -lt ${timeout} ]]; do
        local ps_output
        ps_output="$("${ISTIOCTL}" --context "${CONTEXT}" proxy-status 2>/dev/null | grep "ingress-gw-${TRACK_CANARY}")"
        # Each canary pod row should NOT contain STALE or NOT SENT
        local stale_count
        stale_count="$(echo "${ps_output}" | grep -cE "STALE|NOT SENT" || true)"
        local pod_count
        pod_count="$(echo "${ps_output}" | wc -l | tr -d ' ')"
        if [[ "${stale_count}" -eq 0 ]] && [[ "${pod_count}" -ge 1 ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

run_traffic_and_check_backend() {
    # $1 = expected backend pod, $2 = name of expected backend for messages
    local expected_pod=$1 expected_name=$2 other_pod=$3 other_name=$4
    local pre_expected pre_other post_expected post_other
    pre_expected=$(_logcount "${expected_pod}")
    pre_other=$(_logcount "${other_pod}")
    for i in 1 2 3 4 5; do
        curl -s -o /dev/null -H "Host: demo11.example.com" "http://localhost:${LOCAL_PORT}/headers"
    done
    sleep 1
    post_expected=$(_logcount "${expected_pod}")
    post_other=$(_logcount "${other_pod}")
    local expected_delta=$((post_expected - pre_expected))
    local other_delta=$((post_other - pre_other))
    demo_info "deltas: ${expected_name}=${expected_delta}  ${other_name}=${other_delta}"
    [[ "${expected_delta}" -ge 5 ]] && [[ "${other_delta}" -le 2 ]]
}

# ---------------------------------------------------------------------------
# Step 2: forward path — apply VS-v1, poll for SYNCED, verify routing
# ---------------------------------------------------------------------------
demo_step "Forward path: applying VS-v1, polling proxy-status until SYNCED"
kctl apply -f "${TMPDIR_DEMO}/vs-v1.yaml" >/dev/null
WAIT_START=$(date +%s)
if wait_until_synced 30; then
    WAIT_ELAPSED=$(( $(date +%s) - WAIT_START ))
    demo_assert_pass "Forward-path proxy-status SYNCED in ${WAIT_ELAPSED}s"
else
    WAIT_ELAPSED=$(( $(date +%s) - WAIT_START ))
    demo_assert_fail "Forward-path SYNCED timeout after ${WAIT_ELAPSED}s"
fi

if run_traffic_and_check_backend "${V1_POD}" "v1" "${V2_POD}" "v2"; then
    demo_assert_pass "After VS-v1 apply + SYNCED, traffic routes to v1"
else
    demo_assert_fail "After VS-v1 apply, traffic did not route as expected"
fi

# ---------------------------------------------------------------------------
# Step 3: candidate path — apply VS-v2 (overwrite), poll, verify
# ---------------------------------------------------------------------------
demo_step "Candidate path: applying VS-v2 (overwrites v1), polling until SYNCED"
kctl apply -f "${TMPDIR_DEMO}/vs-v2.yaml" >/dev/null
WAIT_START=$(date +%s)
if wait_until_synced 30; then
    demo_info "Candidate SYNCED in $(( $(date +%s) - WAIT_START ))s"
else
    demo_info "Candidate SYNCED timeout"
fi

if run_traffic_and_check_backend "${V2_POD}" "v2" "${V1_POD}" "v1"; then
    demo_assert_pass "Candidate VS-v2 reached the data plane (traffic now to v2)"
else
    demo_assert_fail "After VS-v2 apply, traffic did not route to v2"
fi

# ---------------------------------------------------------------------------
# Step 4: revert path — apply VS-v1 again ("git revert"), poll, verify
# ---------------------------------------------------------------------------
demo_step "Revert path: re-applying VS-v1 (simulating git revert), polling"
kctl apply -f "${TMPDIR_DEMO}/vs-v1.yaml" >/dev/null
WAIT_START=$(date +%s)
if wait_until_synced 30; then
    WAIT_ELAPSED=$(( $(date +%s) - WAIT_START ))
    demo_assert_pass "Revert-path proxy-status SYNCED in ${WAIT_ELAPSED}s"
else
    WAIT_ELAPSED=$(( $(date +%s) - WAIT_START ))
    demo_assert_fail "Revert-path SYNCED timeout after ${WAIT_ELAPSED}s"
fi

if run_traffic_and_check_backend "${V1_POD}" "v1" "${V2_POD}" "v2"; then
    demo_assert_pass "After revert + SYNCED, traffic back to v1"
else
    demo_assert_fail "After revert, traffic did not go back to v1"
fi

demo_end

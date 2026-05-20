#!/usr/bin/env bash
# ============================================================================
# Demo #08a — Traffic mirroring (classic Istio API: VirtualService.spec.mirror)
# ============================================================================
#
# HYPOTHESIS
#   A VirtualService bound to canary-gateway can route 100% of traffic to
#   httpbin-v1 AND mirror 100% to httpbin-shadow. Mirrored requests are
#   "fire-and-forget" — the shadow service receives them, but its responses
#   are discarded; the client sees only the primary backend's response.
#
#   This is the validation-phase pattern: route real production traffic
#   through a candidate path WITHOUT user-visible risk to confirm the
#   candidate config doesn't crash or 5xx under real payloads.
#
# SETUP
#   Apply a Gateway + VS bound to canary-gateway. VS routes to httpbin-v1
#   and mirrors to httpbin-shadow.
#
# ACTION + VERIFICATION
#   Send 10 requests via port-forward to the canary gateway.
#   PASS:
#     - All client responses are 200 OK
#     - Client responses come from httpbin-v1 (VARIANT env var)
#     - httpbin-shadow pod logs show 10 received requests (fire-and-forget)
#
# PRODUCT-IMPROVEMENT NOTE
#   VirtualService.spec.mirror has `mirrorPercentage` for fractional mirroring.
#   Gateway API RequestMirror filter (#08b) lacks this. Parity gap captured
#   in PLAN.md FR signals.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "08a" "traffic-mirroring-istio" \
  "VirtualService.spec.mirror sends fire-and-forget shadow traffic to a candidate backend"

TMPDIR_DEMO="$(mktemp -d)"
PF_PID=""
cleanup_demo() {
    rm -rf "${TMPDIR_DEMO}"
    [[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true
    kctl delete virtualservice demo08a-vs -n apps --ignore-not-found 2>/dev/null
    kctl delete gateway demo08a-canary-gw -n istio-system --ignore-not-found 2>/dev/null
}
trap cleanup_demo EXIT

# ---------------------------------------------------------------------------
# Step 1: apply Gateway + VS with mirror to shadow
# ---------------------------------------------------------------------------
demo_step "Applying Gateway + VirtualService with route to httpbin-v1, mirror to httpbin-shadow"
cat > "${TMPDIR_DEMO}/manifests.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: demo08a-canary-gw
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
    hosts: ["demo08a.example.com"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: demo08a-vs
  namespace: apps
spec:
  hosts: ["demo08a.example.com"]
  gateways: ["istio-system/demo08a-canary-gw"]
  http:
  - route:
    - destination:
        host: httpbin-v1.apps.svc.cluster.local
        port:
          number: 8000
    mirror:
      host: httpbin-shadow.apps.svc.cluster.local
      port:
        number: 8000
    mirrorPercentage:
      value: 100.0
EOF
kctl apply -f "${TMPDIR_DEMO}/manifests.yaml" >/dev/null
sleep 3

# ---------------------------------------------------------------------------
# Step 2: port-forward to canary gateway Service
# ---------------------------------------------------------------------------
demo_step "Establishing port-forward to canary gateway Service"
LOCAL_PORT=18681
# NOTE: Call kubectl directly (not the kctl function) so $! captures the
# actual kubectl PID, not a function-subshell PID. Otherwise trap cleanup
# kills the wrapper but leaves the kubectl orphaned (port stays bound).
kubectl --context "${CONTEXT}" port-forward -n istio-system \
    "svc/${GATEWAY_APP_LABEL}-${TRACK_CANARY}" "${LOCAL_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
sleep 2
if ! kill -0 "${PF_PID}" 2>/dev/null; then
    demo_assert_fail "port-forward to canary gateway died (PID ${PF_PID})"
    demo_end
    exit $?
fi
demo_info "port-forward localhost:${LOCAL_PORT} -> ingress-gw-canary:80 (pid=${PF_PID})"

# ---------------------------------------------------------------------------
# Step 3: capture pre-test shadow log line count, send 10 requests
# ---------------------------------------------------------------------------
SHADOW_POD="$(kctl get pod -n apps -l app=httpbin,version=shadow -o jsonpath='{.items[0].metadata.name}')"
V1_POD="$(kctl get pod -n apps -l app=httpbin,version=v1 -o jsonpath='{.items[0].metadata.name}')"
demo_info "v1 pod:     ${V1_POD}"
demo_info "shadow pod: ${SHADOW_POD}"

PRE_SHADOW_LOGS="$(kctl logs -n apps "${SHADOW_POD}" 2>/dev/null | wc -l | tr -d ' ')"
PRE_V1_LOGS="$(kctl logs -n apps "${V1_POD}" 2>/dev/null | wc -l | tr -d ' ')"

demo_step "Sending 10 GET /headers requests through canary gateway"
RESPONSE_CODES=""
for i in 1 2 3 4 5 6 7 8 9 10; do
    CODE="$(curl -s -o /dev/null -w "%{http_code}" -H "Host: demo08a.example.com" "http://localhost:${LOCAL_PORT}/headers")"
    RESPONSE_CODES="${RESPONSE_CODES} ${CODE}"
done
demo_info "Response codes:${RESPONSE_CODES}"

# Give shadow service time to receive mirrored requests
sleep 2

# ---------------------------------------------------------------------------
# Step 4: assertions
# ---------------------------------------------------------------------------
# (a) All client responses are 200
NON_200=$(echo "${RESPONSE_CODES}" | tr ' ' '\n' | awk 'NF && $1 != "200"' | wc -l | tr -d ' ')
if [[ "${NON_200}" -eq 0 ]]; then
    demo_assert_pass "All 10 client responses are 200 OK"
else
    demo_assert_fail "Got ${NON_200} non-200 responses out of 10:${RESPONSE_CODES}"
fi

# (b) Both v1 and shadow saw all 10 requests
POST_V1_LOGS="$(kctl logs -n apps "${V1_POD}" 2>/dev/null | wc -l | tr -d ' ')"
POST_SHADOW_LOGS="$(kctl logs -n apps "${SHADOW_POD}" 2>/dev/null | wc -l | tr -d ' ')"
V1_DELTA=$((POST_V1_LOGS - PRE_V1_LOGS))
SHADOW_DELTA=$((POST_SHADOW_LOGS - PRE_SHADOW_LOGS))
demo_info "v1 log delta:     ${V1_DELTA} lines"
demo_info "shadow log delta: ${SHADOW_DELTA} lines"

if [[ "${V1_DELTA}" -ge 10 ]]; then
    demo_assert_pass "httpbin-v1 received ≥10 requests (the primary backend served all client requests)"
else
    demo_assert_fail "httpbin-v1 log delta only ${V1_DELTA}; expected ≥10"
fi

if [[ "${SHADOW_DELTA}" -ge 10 ]]; then
    demo_assert_pass "httpbin-shadow received ≥10 requests (mirror is firing 100%)"
else
    demo_assert_fail "httpbin-shadow log delta only ${SHADOW_DELTA}; expected ≥10"
fi

demo_end

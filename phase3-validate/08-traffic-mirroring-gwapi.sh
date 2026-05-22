#!/usr/bin/env bash
# ============================================================================
# Demo #08b — Traffic mirroring (Kubernetes Gateway API: RequestMirror filter)
# ============================================================================
#
# HYPOTHESIS
#   An HTTPRoute with a `RequestMirror` filter sends a copy of every request
#   to the mirror backend. Same end behavior as VirtualService.spec.mirror
#   (Demo #08a) but expressed through a Gateway API filter.
#
# PRODUCT-IMPROVEMENT NOTE (intentional contrast with #08a)
#   The Gateway API `RequestMirror` filter does NOT include a percentage
#   field. The classic Istio API's `mirrorPercentage` (used in #08a) allows
#   fractional mirroring. This demo confirms the parity gap: the API works,
#   but you can't sub-sample.
#
# SETUP
#   - Apply a Gateway API Gateway in apps (Istio auto-provisions backing pod)
#   - Apply an HTTPRoute with a RequestMirror filter targeting httpbin-shadow,
#     and a backendRefs target of httpbin-v1
#
# VERIFICATION + PASS
#   - 10 client requests through the auto-provisioned gateway, all 200 OK
#   - httpbin-v1 logs grow by ≥10 (primary backend)
#   - httpbin-shadow logs grow by ≥10 (mirror)
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "08b" "traffic-mirroring-gwapi" \
  "HTTPRoute RequestMirror filter sends fire-and-forget shadow traffic (no percentage knob)"

TMPDIR_DEMO="$(mktemp -d)"
PF_PID=""
cleanup_demo() {
    rm -rf "${TMPDIR_DEMO}"
    [[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true
    kctl delete httproute demo08b-route -n apps --ignore-not-found 2>/dev/null
    kctl delete gateway.gateway.networking.k8s.io demo08b-gw -n apps --ignore-not-found 2>/dev/null
}
trap cleanup_demo EXIT

# ---------------------------------------------------------------------------
# Step 1: apply Gateway API Gateway; wait for Istio to provision
# ---------------------------------------------------------------------------
demo_step "Applying Gateway API Gateway demo08b-gw (Istio auto-provisions backing pod)"
cat > "${TMPDIR_DEMO}/manifests.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: demo08b-gw
  namespace: apps
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: "demo08b.example.com"
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: demo08b-route
  namespace: apps
spec:
  parentRefs:
  - name: demo08b-gw
  hostnames:
  - "demo08b.example.com"
  rules:
  - filters:
    - type: RequestMirror
      requestMirror:
        backendRef:
          name: httpbin-shadow
          port: 8000
    backendRefs:
    - name: httpbin-v1
      port: 8000
EOF
kctl apply -f "${TMPDIR_DEMO}/manifests.yaml" >/dev/null

demo_step "Waiting for Istio to provision the backing Deployment..."
for i in $(seq 1 60); do
    READY=$(kctl get deployment demo08b-gw-istio -n apps -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${READY:-0}" -ge 1 ]]; then
        demo_info "demo08b-gw-istio Deployment ready"
        break
    fi
    sleep 1
done
[[ "${READY:-0}" -lt 1 ]] && { demo_assert_fail "Istio did not provision backing pod in 60s"; demo_end; exit $?; }

# Allow istiod to push xDS to the new gateway pod.
wait_until_synced "demo08b-gw-istio" 30 || true

# ---------------------------------------------------------------------------
# Step 2: port-forward to the auto-provisioned gateway Service
# ---------------------------------------------------------------------------
demo_step "Establishing port-forward to demo08b-gw-istio Service"
LOCAL_PORT=18682
PF_PID="$(start_port_forward "${APPS_NS}" "svc/demo08b-gw-istio" "${LOCAL_PORT}:80")" \
    || { demo_assert_fail "port-forward to demo08b-gw-istio failed"; demo_end; exit $?; }
demo_info "port-forward localhost:${LOCAL_PORT} -> demo08b-gw-istio:80 (pid=${PF_PID})"

# ---------------------------------------------------------------------------
# Step 3: capture pre-test log counts, send 10 requests
# ---------------------------------------------------------------------------
V1_POD="$(kctl get pod -n apps -l app=httpbin,version=v1 -o jsonpath='{.items[0].metadata.name}')"
SHADOW_POD="$(kctl get pod -n apps -l app=httpbin,version=shadow -o jsonpath='{.items[0].metadata.name}')"
PRE_V1="$(kctl logs -n apps "${V1_POD}" 2>/dev/null | wc -l | tr -d ' ')"
PRE_SHADOW="$(kctl logs -n apps "${SHADOW_POD}" 2>/dev/null | wc -l | tr -d ' ')"

demo_step "Sending 10 GET /headers requests"
RESPONSE_CODES=""
for i in 1 2 3 4 5 6 7 8 9 10; do
    CODE="$(curl -s -o /dev/null -w "%{http_code}" -H "Host: demo08b.example.com" "http://localhost:${LOCAL_PORT}/headers")"
    RESPONSE_CODES="${RESPONSE_CODES} ${CODE}"
done
demo_info "Response codes:${RESPONSE_CODES}"
sleep 2

# ---------------------------------------------------------------------------
# Step 4: assertions
# ---------------------------------------------------------------------------
NON_200=$(echo "${RESPONSE_CODES}" | tr ' ' '\n' | awk 'NF && $1 != "200"' | wc -l | tr -d ' ')
if [[ "${NON_200}" -eq 0 ]]; then
    demo_assert_pass "All 10 client responses are 200 OK"
else
    demo_assert_fail "Got ${NON_200} non-200 responses out of 10"
fi

POST_V1="$(kctl logs -n apps "${V1_POD}" 2>/dev/null | wc -l | tr -d ' ')"
POST_SHADOW="$(kctl logs -n apps "${SHADOW_POD}" 2>/dev/null | wc -l | tr -d ' ')"
V1_DELTA=$((POST_V1 - PRE_V1))
SHADOW_DELTA=$((POST_SHADOW - PRE_SHADOW))
demo_info "v1 log delta:     ${V1_DELTA}"
demo_info "shadow log delta: ${SHADOW_DELTA}"

if [[ "${V1_DELTA}" -ge 10 ]]; then
    demo_assert_pass "httpbin-v1 received ≥10 requests (primary backend)"
else
    demo_assert_fail "httpbin-v1 delta ${V1_DELTA} < 10"
fi

if [[ "${SHADOW_DELTA}" -ge 10 ]]; then
    demo_assert_pass "httpbin-shadow received ≥10 requests (RequestMirror filter firing)"
else
    demo_assert_fail "httpbin-shadow delta ${SHADOW_DELTA} < 10"
fi

# ---------------------------------------------------------------------------
# Final note: emphasize the parity gap surfaced in the docs/educational case
# ---------------------------------------------------------------------------
echo ""
echo "  NOTE (FR signal): Gateway API RequestMirror filter has no 'percentage'"
echo "  field. To sub-sample mirroring with Gateway API, the only paths are"
echo "  ExtensionRef filters or routing to a fractional-mirroring proxy.    "
echo "  Compare with Demo #08a where VirtualService.spec.mirrorPercentage    "
echo "  provides this directly.                                              "

demo_end

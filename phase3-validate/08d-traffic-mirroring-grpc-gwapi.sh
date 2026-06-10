#!/usr/bin/env bash
# ============================================================================
# Demo #08d — gRPC mirroring via Kubernetes Gateway API (GRPCRoute + RequestMirror)
# ============================================================================
#
# HYPOTHESIS
#   Gateway API's `GRPCRoute` (v1, Gateway API 1.2+) supports a
#   `RequestMirror` filter analogous to HTTPRoute's. With gatewayClassName=istio
#   the route lands on an auto-provisioned Istio gateway pod. The PASS shape
#   is the same as #08c (VirtualService.spec.mirror): primary gets all calls,
#   shadow receives a fire-and-forget copy.
#
# PRODUCT-IMPROVEMENT WATCHPOINTS
#   - If GRPCRoute's RequestMirror lacks `percentage` (or its Gateway API
#     equivalent) parity with VS.spec.mirror.mirrorPercentage, that's the
#     same parity gap surfaced by #08b for HTTPRoute. Document inline.
#   - If gRPC mirror via GRPCRoute behaves differently than VS.spec.mirror
#     (e.g., shadow receives fewer requests, different status code
#     distribution), that's a real FR finding for Solo.
#
# SETUP / ACTION
#   - Gateway API Gateway (gatewayClassName=istio) on apps namespace
#   - GRPCRoute with backendRefs=grpcbin and filters=[RequestMirror→grpcbin-shadow]
#   - ghz from loadgen sends 30 unary calls via the auto-provisioned gateway
#
# VERIFICATION + PASS
#   - 30/30 ghz responses are OK
#   - Primary AND shadow upstream_rq_completed both grew by ≥30 on the
#     auto-provisioned gateway pod (the standard "internal" stat-bucket
#     pattern applies as in #08c)
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "08d" "traffic-mirroring-grpc-gwapi" \
  "GRPCRoute RequestMirror sends fire-and-forget gRPC shadow copies (Gateway API equivalent of #08c)"

TMPDIR_DEMO="$(mktemp -d)"
cleanup_demo() {
    rm -rf "${TMPDIR_DEMO}"
    kctl delete grpcroute demo08d-route -n apps --ignore-not-found 2>/dev/null
    kctl delete gateway.gateway.networking.k8s.io demo08d-gw -n apps --ignore-not-found 2>/dev/null
}
trap cleanup_demo EXIT

# ---------------------------------------------------------------------------
# Step 1: Gateway API Gateway + GRPCRoute (RequestMirror filter)
# ---------------------------------------------------------------------------
demo_step "Applying Gateway API Gateway + GRPCRoute with RequestMirror filter"
cat > "${TMPDIR_DEMO}/manifests.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: demo08d-gw
  namespace: apps
  annotations:
    # Propagate broader proxyStatsMatcher to the auto-provisioned gateway
    # pod so upstream_rq_completed is visible for demo verification.
    proxy.istio.io/config: |
      proxyStatsMatcher:
        inclusionRegexps:
          - ".*upstream_rq.*"
          - ".*upstream_cx.*"
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: "demo08d.example.com"
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata: {name: demo08d-route, namespace: apps}
spec:
  parentRefs:
  - name: demo08d-gw
  hostnames:
  - "demo08d.example.com"
  rules:
  - filters:
    - type: RequestMirror
      requestMirror:
        backendRef:
          name: grpcbin-shadow
          port: 9000
    backendRefs:
    - name: grpcbin
      port: 9000
EOF
kctl apply -f "${TMPDIR_DEMO}/manifests.yaml" >/dev/null

# Wait for Istio to auto-provision the backing Deployment + Service
demo_step "Waiting for Istio to provision the backing Deployment..."
for i in $(seq 1 60); do
    READY=$(kctl get deployment demo08d-gw-istio -n apps -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${READY:-0}" -ge 1 ]]; then
        demo_info "demo08d-gw-istio Deployment ready"
        break
    fi
    sleep 1
done
[[ "${READY:-0}" -lt 1 ]] && { demo_assert_fail "Istio did not provision backing pod in 60s"; demo_end; exit $?; }

# ---------------------------------------------------------------------------
# Step 2: identify pods and capture baseline upstream_rq stats
# ---------------------------------------------------------------------------
GHZ_POD="$(kctl get pod -n "${LOADGEN_NS}" -l app=ghz -o jsonpath='{.items[0].metadata.name}')"
GW_PODS=$(kctl get pod -n "${APPS_NS}" -l "gateway.networking.k8s.io/gateway-name=demo08d-gw" -o jsonpath='{.items[*].metadata.name}')
# Poll the auto-provisioned pod's route table for the new host before sending traffic.
FIRST_GW="${GW_PODS%% *}"
wait_pc_match "${FIRST_GW}.${APPS_NS}" routes "demo08d.example.com" 30 || true
demo_info "ghz pod:    ${GHZ_POD}"
demo_info "gwapi pods: ${GW_PODS}"

# envoy_upstream_rq (from lib/pass-fail.sh) sums across both external+internal
# buckets on every auto-provisioned gateway pod (Gateway API typically deploys
# 1 replica but we iterate for safety).
_rq() { envoy_upstream_rq "$1" "${APPS_NS}" 9000 "${APPS_NS}" "${GW_PODS}"; }

PRE_PRIMARY=$(_rq grpcbin); PRE_PRIMARY=${PRE_PRIMARY:-0}
PRE_SHADOW=$(_rq grpcbin-shadow); PRE_SHADOW=${PRE_SHADOW:-0}
demo_info "Pre-load upstream_rq_completed: primary=${PRE_PRIMARY}, shadow=${PRE_SHADOW}"

# ---------------------------------------------------------------------------
# Step 3: send 30 gRPC calls through the auto-provisioned gateway
# ---------------------------------------------------------------------------
demo_step "Sending 30 gRPC calls via ghz through demo08d-gw"
GHZ_OUT="${TMPDIR_DEMO}/ghz.out"
kctl exec -n "${LOADGEN_NS}" "${GHZ_POD}" -- /usr/local/bin/ghz \
    --insecure --connections=1 --concurrency=2 --total=30 \
    --format=json \
    --authority=demo08d.example.com \
    --call=grpcbin.GRPCBin/DummyUnary --data='{}' \
    "demo08d-gw-istio.${APPS_NS}.svc.cluster.local:80" > "${GHZ_OUT}" 2>&1

demo_info "ghz summary:"
jq -r '"        count=\(.count) ok=\(.statusCodeDistribution.OK // 0) avg=\(.average / 1000000 | floor)ms rps=\(.rps | floor)"' "${GHZ_OUT}" 2>/dev/null \
    || echo "        (ghz json parse failed; raw output: $(head -c 200 "${GHZ_OUT}"))"
sleep 3

POST_PRIMARY=$(_rq grpcbin); POST_PRIMARY=${POST_PRIMARY:-0}
POST_SHADOW=$(_rq grpcbin-shadow); POST_SHADOW=${POST_SHADOW:-0}
PRIMARY_DELTA=$((POST_PRIMARY - PRE_PRIMARY))
SHADOW_DELTA=$((POST_SHADOW - PRE_SHADOW))
demo_info "Post-load deltas: primary=${PRIMARY_DELTA}, shadow=${SHADOW_DELTA}"

# ---------------------------------------------------------------------------
# Assertions (same shape as #08c)
# ---------------------------------------------------------------------------
OK_COUNT=$(jq -r '.statusCodeDistribution.OK // 0' "${GHZ_OUT}" 2>/dev/null)
OK_COUNT=${OK_COUNT:-0}
if [[ "${OK_COUNT}" -eq 30 ]]; then
    demo_assert_pass "All 30 ghz responses were OK"
else
    demo_assert_fail "ghz reported ${OK_COUNT}/30 OK"
fi

if [[ "${PRIMARY_DELTA}" -ge 30 ]]; then
    demo_assert_pass "grpcbin primary upstream_rq_completed grew by ${PRIMARY_DELTA} (≥30)"
else
    demo_assert_fail "grpcbin primary delta ${PRIMARY_DELTA} < 30"
fi

if [[ "${SHADOW_DELTA}" -ge 30 ]]; then
    demo_assert_pass "grpcbin-shadow upstream_rq_completed grew by ${SHADOW_DELTA} (≥30; GRPCRoute RequestMirror firing)"
else
    demo_assert_fail "grpcbin-shadow delta ${SHADOW_DELTA} < 30 (RequestMirror not firing in GRPCRoute)"
fi

echo ""
echo "  NOTE (FR signal): Gateway API GRPCRoute RequestMirror filter does"
echo "  NOT support a percentage field (same parity gap as HTTPRoute     "
echo "  RequestMirror in #08b vs VS.spec.mirrorPercentage in #08c). For   "
echo "  Solo customers wanting fractional gRPC mirroring through Gateway   "
echo "  API, the only options today are ExtensionRef filters or routing   "
echo "  through a separate fractional-sampling proxy.                     "
demo_end

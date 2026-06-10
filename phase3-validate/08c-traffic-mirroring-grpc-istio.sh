#!/usr/bin/env bash
# ============================================================================
# Demo #08c — gRPC mirroring via classic Istio API (VirtualService.spec.mirror)
# ============================================================================
#
# HYPOTHESIS
#   VirtualService.spec.mirror works for gRPC traffic the same way it does
#   for HTTP/1.1 (Demo #08a): the primary backend serves all gRPC responses;
#   the shadow backend receives a fire-and-forget copy of every request.
#
#   For gRPC specifically, the question of interest is whether trailers,
#   gRPC-status, and HTTP/2 stream lifecycle are preserved on the mirror
#   path. If they're not, the shadow's responses (which are discarded) could
#   leak failures into Envoy stats or cause client-visible behavior changes.
#
# PRODUCT-IMPROVEMENT WATCHPOINTS
#   Compare upstream_rq_completed counts and any RX/TX irregularities
#   between primary and shadow clusters. If shadow exhibits a sharply
#   different completed/error ratio under the same workload, that's an FR
#   signal: gRPC mirror lacks trailer-aware handling.
#
# SETUP / ACTION
#   - Gateway + VS bound to canary-gateway routing demo08c.example.com →
#     grpcbin (primary), mirroring 100% to grpcbin-shadow.
#   - ghz sends 30 unary gRPC calls from the loadgen namespace.
#
# VERIFICATION + PASS
#   - All 30 ghz responses are OK.
#   - Envoy stats on the canary gateway show primary upstream_rq_completed
#     grew by ≥30 AND shadow upstream_rq_completed grew by ≥30.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "08c" "traffic-mirroring-grpc-istio" \
  "VS.spec.mirror replicates gRPC traffic to a shadow destination (fire-and-forget)"

TMPDIR_DEMO="$(mktemp -d)"
cleanup_demo() {
    rm -rf "${TMPDIR_DEMO}"
    kctl delete virtualservice demo08c-vs -n apps --ignore-not-found 2>/dev/null
    kctl delete gateway demo08c-canary-gw -n istio-system --ignore-not-found 2>/dev/null
}
trap cleanup_demo EXIT

demo_step "Applying Gateway + VirtualService with route to grpcbin, mirror to grpcbin-shadow (100%)"
cat > "${TMPDIR_DEMO}/manifests.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata: {name: demo08c-canary-gw, namespace: istio-system}
spec:
  selector: {app: ${GATEWAY_APP_LABEL}, ${TRACK_LABEL_KEY}: ${TRACK_CANARY}}
  servers:
  - port: {number: 80, name: http, protocol: HTTP}
    hosts: ["demo08c.example.com"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: demo08c-vs, namespace: apps}
spec:
  hosts: ["demo08c.example.com"]
  gateways: ["istio-system/demo08c-canary-gw"]
  http:
  - match: [{port: 80}]
    route:
    - destination:
        host: grpcbin.apps.svc.cluster.local
        port: {number: 9000}
    mirror:
      host: grpcbin-shadow.apps.svc.cluster.local
      port: {number: 9000}
    mirrorPercentage: {value: 100.0}
EOF
kctl apply -f "${TMPDIR_DEMO}/manifests.yaml" >/dev/null

GHZ_POD="$(kctl get pod -n "${LOADGEN_NS}" -l app=ghz -o jsonpath='{.items[0].metadata.name}')"
# All canary gateway pod names (Service load-balances ghz's single connection
# to ONE of them; we sum stats across all replicas to find the actual hit pod).
CANARY_GW_PODS=$(kctl get pod -n "${SYSTEM_NS}" -l "app=${GATEWAY_APP_LABEL},${TRACK_LABEL_KEY}=${TRACK_CANARY}" -o jsonpath='{.items[*].metadata.name}')
demo_info "ghz pod:        ${GHZ_POD}"
demo_info "canary gw pods: ${CANARY_GW_PODS}"

# Poll one canary gateway pod's route table for the new host. Stronger
# signal than `wait_until_synced` alone — see lib/pass-fail.sh.
FIRST_CANARY="${CANARY_GW_PODS%% *}"
wait_pc_match "${FIRST_CANARY}.${SYSTEM_NS}" routes "demo08c.example.com" 30 || true

# envoy_upstream_rq (from lib/pass-fail.sh) sums upstream_rq_completed across
# all canary gateway pods AND both Envoy stat buckets (.external + .internal —
# mirror traffic lands in .internal).
_rq() { envoy_upstream_rq "$1" "${APPS_NS}" 9000 "${SYSTEM_NS}" "${CANARY_GW_PODS}"; }

PRE_PRIMARY=$(_rq grpcbin); PRE_PRIMARY=${PRE_PRIMARY:-0}
PRE_SHADOW=$(_rq grpcbin-shadow); PRE_SHADOW=${PRE_SHADOW:-0}
demo_info "Pre-load upstream_rq_completed: primary=${PRE_PRIMARY}, shadow=${PRE_SHADOW}"

demo_step "Sending 30 gRPC calls via ghz (DummyUnary)"
GHZ_OUT="${TMPDIR_DEMO}/ghz.out"
kctl exec -n "${LOADGEN_NS}" "${GHZ_POD}" -- /usr/local/bin/ghz \
    --insecure --connections=1 --concurrency=2 --total=30 \
    --format=json \
    --authority=demo08c.example.com \
    --call=grpcbin.GRPCBin/DummyUnary --data='{}' \
    "${GATEWAY_APP_LABEL}-${TRACK_CANARY}.${SYSTEM_NS}.svc.cluster.local:80" > "${GHZ_OUT}" 2>&1

# Show ghz summary parsed from JSON. The previous awk-on-text approach was
# coupled to ghz v0.120.0's exact "  [OK]" summary indentation; JSON is the
# stable interface.
demo_info "ghz summary:"
jq -r '"        count=\(.count) ok=\(.statusCodeDistribution.OK // 0) avg=\(.average / 1000000 | floor)ms rps=\(.rps | floor)"' "${GHZ_OUT}" 2>/dev/null \
    || echo "        (ghz json parse failed; raw output: $(head -c 200 "${GHZ_OUT}"))"

# Allow the mirrored traffic to land on the shadow cluster
sleep 3
POST_PRIMARY=$(_rq grpcbin); POST_PRIMARY=${POST_PRIMARY:-0}
POST_SHADOW=$(_rq grpcbin-shadow); POST_SHADOW=${POST_SHADOW:-0}
PRIMARY_DELTA=$((POST_PRIMARY - PRE_PRIMARY))
SHADOW_DELTA=$((POST_SHADOW - PRE_SHADOW))
demo_info "Post-load deltas: primary=${PRIMARY_DELTA}, shadow=${SHADOW_DELTA}"

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
# (a) ghz must report 30/30 OK responses
OK_COUNT=$(jq -r '.statusCodeDistribution.OK // 0' "${GHZ_OUT}" 2>/dev/null)
OK_COUNT=${OK_COUNT:-0}
if [[ "${OK_COUNT}" -eq 30 ]]; then
    demo_assert_pass "All 30 ghz responses were OK (mirror is fire-and-forget; client unaffected)"
else
    demo_assert_fail "ghz reported ${OK_COUNT}/30 OK; mirror may be affecting client responses"
fi

# (b) Primary cluster received all 30
if [[ "${PRIMARY_DELTA}" -ge 30 ]]; then
    demo_assert_pass "grpcbin primary upstream_rq_completed grew by ${PRIMARY_DELTA} (≥30)"
else
    demo_assert_fail "grpcbin primary delta ${PRIMARY_DELTA} < 30"
fi

# (c) Shadow cluster received all 30 (100% mirror)
if [[ "${SHADOW_DELTA}" -ge 30 ]]; then
    demo_assert_pass "grpcbin-shadow upstream_rq_completed grew by ${SHADOW_DELTA} (≥30; mirror firing 100%)"
else
    demo_assert_fail "grpcbin-shadow delta ${SHADOW_DELTA} < 30 (mirror not firing)"
fi

echo ""
echo "  NOTE (FR signal watchpoint): with 100% mirror, primary and shadow"
echo "  should have IDENTICAL completed counts. If they diverge under load, "
echo "  shadow's gRPC trailer / status handling may be incomplete in Envoy. "
echo "  Compare also against #08a (HTTP/1.1) baseline to see if gRPC-       "
echo "  specific irregularities surface that don't appear for HTTP/1.1.    "
demo_end

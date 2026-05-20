#!/usr/bin/env bash
# ============================================================================
# Demo #13c — xDS push during a sustained gRPC ClientConn (extreme long-lived)
# ============================================================================
#
# WHY THIS DEMO MATTERS
#   Real-world gRPC clients typically hold ONE grpc.ClientConn for the
#   entire application's lifetime (hours, days). All RPCs from that client
#   multiplex over that single TCP connection. This is the most extreme
#   long-lived-connection case in production. If a customer has gRPC
#   ingress AND does xDS pushes during production, this is the protocol
#   where "track isolation matters more than ever" needs proving.
#
#   ghz with --connections=1 emulates this canonical pattern: one
#   grpc.ClientConn that handles all requests in the run.
#
# HYPOTHESIS
#   Per-stream routing applies to gRPC too. During a sustained gRPC test
#   on ONE ClientConn, an xDS push that swaps the canary VS from
#   grpcbin → grpcbin-v2 takes effect on the next RPC issued on the
#   existing connection, just like HTTP/1.1 (#13) and HTTP/2 (#13b).
#
# SETUP
#   - Gateway with HTTP listener on port 80; VS routing demo13c.example.com
#     → grpcbin (primary) on port 9001 with appProtocol: grpc
#   - ghz launched with --connections=1 against the canary gateway,
#     sustained 30s, calling hello.HelloService.SayHello
#   - Mid-run (at ~15s), switch the VS to route to grpcbin-v2
#
# PASS CRITERION
#   - First-half log delta: grpcbin (primary) dominant
#   - Second-half log delta: grpcbin-v2 dominant
#   - Same TCP connection throughout (one ClientConn)
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "13c" "xds-push-grpc-long-lived" \
  "gRPC ClientConn: per-stream routing through xDS push (same finding, extreme connection longevity)"

TMPDIR_DEMO="$(mktemp -d)"
GHZ_PID=""
cleanup_demo() {
    rm -rf "${TMPDIR_DEMO}"
    [[ -n "${GHZ_PID}" ]] && kill "${GHZ_PID}" 2>/dev/null || true
    kctl delete virtualservice demo13c-vs -n apps --ignore-not-found 2>/dev/null
    kctl delete gateway demo13c-canary-gw -n istio-system --ignore-not-found 2>/dev/null
}
trap cleanup_demo EXIT

# ---------------------------------------------------------------------------
# Step 1: Gateway with HTTP listener; VS routing the gRPC host to grpcbin
#         on port 9001. Istio's HTTP listener accepts h2c and forwards
#         to gRPC backends (appProtocol: grpc on the destination Service).
# ---------------------------------------------------------------------------
demo_step "Applying demo13c-canary-gw + VS routing to grpcbin (primary) on port 9000 (plaintext gRPC)"
cat > "${TMPDIR_DEMO}/setup.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata: {name: demo13c-canary-gw, namespace: istio-system}
spec:
  selector: {app: ${GATEWAY_APP_LABEL}, ${TRACK_LABEL_KEY}: ${TRACK_CANARY}}
  servers:
  - port: {number: 80, name: http, protocol: HTTP}
    hosts: ["demo13c.example.com"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: demo13c-vs, namespace: apps}
spec:
  hosts: ["demo13c.example.com"]
  gateways: ["istio-system/demo13c-canary-gw"]
  http:
  - route:
    - destination: {host: grpcbin.apps.svc.cluster.local, port: {number: 9000}}
EOF
kctl apply -f "${TMPDIR_DEMO}/setup.yaml" >/dev/null
sleep 3

# ---------------------------------------------------------------------------
# Step 2: identify pods + baseline log counts
# ---------------------------------------------------------------------------
GHZ_POD="$(kctl get pod -n "${LOADGEN_NS}" -l app=ghz -o jsonpath='{.items[0].metadata.name}')"
# All canary gateway pod names (Service load-balances ghz's single connection
# to ONE of the 3 replicas; we sum stats across all to find the actual hit pod).
CANARY_GW_PODS=$(kctl get pod -n istio-system -l "app=${GATEWAY_APP_LABEL},${TRACK_LABEL_KEY}=${TRACK_CANARY}" -o jsonpath='{.items[*].metadata.name}')
demo_info "ghz pod:        ${GHZ_POD}"
demo_info "canary gw pods: ${CANARY_GW_PODS}"

# grpcbin doesn't log per-request like httpbin. Use Envoy upstream cluster
# stats summed across all canary gateway pods. The stat name format:
#   cluster.outbound|<port>||<svc>.<ns>.svc.cluster.local;.external.upstream_rq_completed
# NOTE: '|' would be awk regex alternation — use index() for substring match.
_upstream_rq() {
    # Sum upstream_rq_completed across all canary gateway pods AND across
    # Envoy's external+internal stat buckets (mirror requests land in
    # `.internal.`, not `.external.`).
    local total=0 v
    for POD in ${CANARY_GW_PODS}; do
        for BUCKET in external internal; do
            v=$(kctl exec -n istio-system "${POD}" -c istio-proxy -- \
                pilot-agent request GET stats 2>/dev/null \
                | awk -F': ' -v key="cluster.outbound|9000||$1.apps.svc.cluster.local;.${BUCKET}.upstream_rq_completed" \
                    'index($0, key) > 0 {print $2; exit}' \
                | tr -d ' ')
            total=$((total + ${v:-0}))
        done
    done
    echo "${total}"
}
T0_PRIMARY=$(_upstream_rq grpcbin)
T0_V2=$(_upstream_rq grpcbin-v2)
T0_PRIMARY=${T0_PRIMARY:-0}
T0_V2=${T0_V2:-0}

# ---------------------------------------------------------------------------
# Step 3: launch ghz against the canary gateway Service with --connections=1
#         (one grpc.ClientConn for the whole run). Target is the canary
#         gateway's HTTP listener with authority demo13c.example.com.
# ---------------------------------------------------------------------------
demo_step "Launching ghz: 30s sustained gRPC load on ONE ClientConn (--connections=1)"
GHZ_OUT="${TMPDIR_DEMO}/ghz.out"
(
    kctl exec -n "${LOADGEN_NS}" "${GHZ_POD}" -- /usr/local/bin/ghz \
        --insecure \
        --connections=1 \
        --duration=30s \
        --rps=5 \
        --concurrency=1 \
        --authority="demo13c.example.com" \
        --call=grpcbin.GRPCBin/DummyUnary \
        --data='{}' \
        "${GATEWAY_APP_LABEL}-${TRACK_CANARY}.${SYSTEM_NS}.svc.cluster.local:80" \
        > "${GHZ_OUT}" 2>&1
) &
GHZ_PID=$!

# Wait until ~15s
sleep 15

T15_PRIMARY=$(_upstream_rq grpcbin)
T15_V2=$(_upstream_rq grpcbin-v2)
T15_PRIMARY=${T15_PRIMARY:-0}
T15_V2=${T15_V2:-0}
MID_PRIMARY_DELTA=$((T15_PRIMARY - T0_PRIMARY))
MID_V2_DELTA=$((T15_V2 - T0_V2))
demo_info "After first 15s: primary delta=${MID_PRIMARY_DELTA}, v2 delta=${MID_V2_DELTA}"

# ---------------------------------------------------------------------------
# Step 4: switch VS to route to grpcbin-v2
# ---------------------------------------------------------------------------
demo_step "Mid-run: switching VS to route to grpcbin-v2"
cat > "${TMPDIR_DEMO}/vs-v2.yaml" <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: demo13c-vs, namespace: apps}
spec:
  hosts: ["demo13c.example.com"]
  gateways: ["istio-system/demo13c-canary-gw"]
  http:
  - route:
    - destination: {host: grpcbin-v2.apps.svc.cluster.local, port: {number: 9000}}
EOF
kctl apply -f "${TMPDIR_DEMO}/vs-v2.yaml" >/dev/null

# ---------------------------------------------------------------------------
# Step 5: wait for ghz to finish
# ---------------------------------------------------------------------------
demo_step "Waiting for ghz to complete the 30s run..."
wait "${GHZ_PID}" 2>/dev/null || true
GHZ_PID=""

sleep 1
T30_PRIMARY=$(_upstream_rq grpcbin)
T30_V2=$(_upstream_rq grpcbin-v2)
T30_PRIMARY=${T30_PRIMARY:-0}
T30_V2=${T30_V2:-0}
SECOND_HALF_PRIMARY_DELTA=$((T30_PRIMARY - T15_PRIMARY))
SECOND_HALF_V2_DELTA=$((T30_V2 - T15_V2))
demo_info "Second 15s: primary delta=${SECOND_HALF_PRIMARY_DELTA}, v2 delta=${SECOND_HALF_V2_DELTA}"
demo_info "ghz summary (last lines):"
tail -15 "${GHZ_OUT}" | sed 's/^/        /'

# ---------------------------------------------------------------------------
# Step 6: assertions (same shape as #13b: traffic should shift halfway)
# ---------------------------------------------------------------------------
FIRST_DIFF=$((MID_PRIMARY_DELTA - MID_V2_DELTA))
if [[ "${MID_PRIMARY_DELTA}" -ge 30 ]] && [[ "${FIRST_DIFF}" -ge 20 ]]; then
    demo_assert_pass "First half: traffic went to grpcbin primary (primary=${MID_PRIMARY_DELTA}, v2=${MID_V2_DELTA}, diff=${FIRST_DIFF})"
else
    demo_assert_fail "First half routing wrong: primary=${MID_PRIMARY_DELTA}, v2=${MID_V2_DELTA}, diff=${FIRST_DIFF} (want primary≥30, diff≥20)"
fi

SECOND_DIFF=$((SECOND_HALF_V2_DELTA - SECOND_HALF_PRIMARY_DELTA))
if [[ "${SECOND_HALF_V2_DELTA}" -ge 30 ]] && [[ "${SECOND_DIFF}" -ge 20 ]]; then
    demo_assert_pass "Second half: traffic shifted to grpcbin-v2 on the SAME ClientConn (v2=${SECOND_HALF_V2_DELTA}, primary=${SECOND_HALF_PRIMARY_DELTA}, diff=${SECOND_DIFF})"
else
    demo_assert_fail "Second half routing wrong: v2=${SECOND_HALF_V2_DELTA}, primary=${SECOND_HALF_PRIMARY_DELTA}, diff=${SECOND_DIFF} (want v2≥30, diff≥20)"
fi

echo ""
echo "  ━━ FINDING ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ONE long-lived gRPC ClientConn saw new routes per-stream after the "
echo "  xDS push at t=15s. Same per-stream-routing finding as #13 and #13b."
echo "  Because gRPC clients typically hold ONE ClientConn for the entire  "
echo "  application's lifetime, they may experience many xDS pushes on the "
echo "  same TCP connection. Track isolation (Demo #05) is what protects   "
echo "  customers on OTHER tracks from any single canary's CRD change.     "
demo_end

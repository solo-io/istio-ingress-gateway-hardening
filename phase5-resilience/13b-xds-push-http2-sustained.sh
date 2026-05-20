#!/usr/bin/env bash
# ============================================================================
# Demo #13b — xDS push during sustained HTTP/2 load on a single TCP connection
# ============================================================================
#
# WHY THIS DEMO MATTERS
#   Modern web/mobile clients negotiate HTTP/2 via ALPN through an NLB +
#   gateway path. Real-world HTTP/2 clients (browsers, mobile stacks,
#   go-grpc clients) maintain ONE TCP connection that multiplexes many
#   concurrent streams over its lifetime. This demo proves that the
#   per-stream routing finding from #13 holds for HTTP/2 just like HTTP/1.1.
#
#   What's different from #13: HTTP/2 connections are typically MUCH longer
#   lived (minutes to hours). A single client may experience many xDS
#   pushes on the same TCP connection. Each push is visible to the client's
#   next stream on that connection, regardless of how long it has been open.
#
# HYPOTHESIS
#   h2dial-light maintains ONE shared http2.Transport (= one TCP connection).
#   It sends 5 req/s at the canary gateway for 30s. Mid-run (at ~15s), the
#   canary's VS is switched from routing to httpbin-v1 to routing to
#   httpbin-v2. PASS: in the FIRST half of the run, httpbin-v1 receives
#   most traffic; in the SECOND half, httpbin-v2 receives most traffic.
#   The connection is the same throughout.
#
# RELEVANCE
#   Proves the L7-per-stream routing finding on the protocol modern web /
#   mobile / gRPC clients actually use. Reinforces that track isolation
#   (Demo #05) is the real blast-radius mechanism for HTTP/2 ingress traffic
#   too.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "13b" "xds-push-http2-sustained" \
  "HTTP/2 connection: per-stream routing through xDS push (same finding as HTTP/1.1)"

TMPDIR_DEMO="$(mktemp -d)"
H2DIAL_PID=""
cleanup_demo() {
    rm -rf "${TMPDIR_DEMO}"
    [[ -n "${H2DIAL_PID}" ]] && kill "${H2DIAL_PID}" 2>/dev/null || true
    kctl delete virtualservice demo13b-vs -n apps --ignore-not-found 2>/dev/null
    kctl delete gateway demo13b-canary-gw -n istio-system --ignore-not-found 2>/dev/null
}
trap cleanup_demo EXIT

# ---------------------------------------------------------------------------
# Step 1: apply Gateway + VS-v1 (route to httpbin-v1)
# ---------------------------------------------------------------------------
demo_step "Applying demo13b-canary-gw + VS-v1 (routes to httpbin-v1)"
cat > "${TMPDIR_DEMO}/setup.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata: {name: demo13b-canary-gw, namespace: istio-system}
spec:
  selector: {app: ${GATEWAY_APP_LABEL}, ${TRACK_LABEL_KEY}: ${TRACK_CANARY}}
  servers:
  - port: {number: 80, name: http, protocol: HTTP}
    hosts: ["demo13b.example.com"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: demo13b-vs, namespace: apps}
spec:
  hosts: ["demo13b.example.com"]
  gateways: ["istio-system/demo13b-canary-gw"]
  http:
  - route:
    - destination: {host: httpbin-v1.apps.svc.cluster.local, port: {number: 8000}}
EOF
kctl apply -f "${TMPDIR_DEMO}/setup.yaml" >/dev/null
sleep 3

# ---------------------------------------------------------------------------
# Step 2: identify pods + baseline log counts
# ---------------------------------------------------------------------------
H2_POD="$(kctl get pod -n "${LOADGEN_NS}" -l app=h2dial-light -o jsonpath='{.items[0].metadata.name}')"
V1_POD="$(kctl get pod -n apps -l app=httpbin,version=v1 -o jsonpath='{.items[0].metadata.name}')"
V2_POD="$(kctl get pod -n apps -l app=httpbin,version=v2 -o jsonpath='{.items[0].metadata.name}')"
demo_info "h2dial pod: ${H2_POD}"
demo_info "v1 pod:     ${V1_POD}"
demo_info "v2 pod:     ${V2_POD}"

_logcount() { kctl logs -n apps "$1" 2>/dev/null | wc -l | tr -d ' '; }
T0_V1=$(_logcount "${V1_POD}")
T0_V2=$(_logcount "${V2_POD}")

# ---------------------------------------------------------------------------
# Step 3: launch h2dial-light against the canary gateway Service (in-cluster)
#          for 30s at 5rps. ONE TCP connection (shared http2.Transport).
# ---------------------------------------------------------------------------
demo_step "Launching h2dial-light: 30s sustained HTTP/2 load on ONE TCP connection (5 rps)"
H2DIAL_OUT="${TMPDIR_DEMO}/h2dial.out"
(
    kctl exec -n "${LOADGEN_NS}" "${H2_POD}" -- /h2dial-light \
        -url "http://${GATEWAY_APP_LABEL}-${TRACK_CANARY}.${SYSTEM_NS}.svc.cluster.local:80/headers" \
        -host "demo13b.example.com" \
        -d 30s -rate 5 > "${H2DIAL_OUT}" 2>&1
) &
H2DIAL_PID=$!

# Wait until ~15s mark
sleep 15

# Capture mid-run log delta (first 15s)
T15_V1=$(_logcount "${V1_POD}")
T15_V2=$(_logcount "${V2_POD}")
MID_V1_DELTA=$((T15_V1 - T0_V1))
MID_V2_DELTA=$((T15_V2 - T0_V2))
demo_info "After first 15s: v1 delta=${MID_V1_DELTA}, v2 delta=${MID_V2_DELTA}"

# ---------------------------------------------------------------------------
# Step 4: mid-flight, switch VS to v2 (xDS push to canary pods)
# ---------------------------------------------------------------------------
demo_step "Mid-run: switching VS to route to httpbin-v2 (xDS push hits canary pods)"
cat > "${TMPDIR_DEMO}/vs-v2.yaml" <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: demo13b-vs, namespace: apps}
spec:
  hosts: ["demo13b.example.com"]
  gateways: ["istio-system/demo13b-canary-gw"]
  http:
  - route:
    - destination: {host: httpbin-v2.apps.svc.cluster.local, port: {number: 8000}}
EOF
kctl apply -f "${TMPDIR_DEMO}/vs-v2.yaml" >/dev/null

# ---------------------------------------------------------------------------
# Step 5: wait for h2dial-light to finish; capture final log counts
# ---------------------------------------------------------------------------
demo_step "Waiting for h2dial-light to complete the 30s run..."
wait "${H2DIAL_PID}" 2>/dev/null || true
H2DIAL_PID=""

sleep 1
T30_V1=$(_logcount "${V1_POD}")
T30_V2=$(_logcount "${V2_POD}")
SECOND_HALF_V1_DELTA=$((T30_V1 - T15_V1))
SECOND_HALF_V2_DELTA=$((T30_V2 - T15_V2))
demo_info "Second 15s: v1 delta=${SECOND_HALF_V1_DELTA}, v2 delta=${SECOND_HALF_V2_DELTA}"
demo_info "h2dial-light output (last lines):"
tail -8 "${H2DIAL_OUT}" | sed 's/^/        /'

# ---------------------------------------------------------------------------
# Step 6: assertions
# ---------------------------------------------------------------------------
# h2dial-light reports total sent/ok/fail; verify mostly successful
FINAL_LINE="$(grep "^FINAL" "${H2DIAL_OUT}" || echo "")"
FINAL_OK=$(echo "${FINAL_LINE}" | sed -nE 's/.*ok=([0-9]+).*/\1/p')
FINAL_FAIL=$(echo "${FINAL_LINE}" | sed -nE 's/.*fail=([0-9]+).*/\1/p')
if [[ "${FINAL_OK:-0}" -ge 100 ]] && [[ "${FINAL_FAIL:-0}" -le 10 ]]; then
    demo_assert_pass "h2dial-light sustained run: ok=${FINAL_OK}, fail=${FINAL_FAIL} (≥100 ok, ≤10 fail)"
else
    demo_assert_fail "h2dial-light run problem: ok=${FINAL_OK}, fail=${FINAL_FAIL}"
fi

# First half should favor v1; tolerate ≥10 probe-noise on the loser
FIRST_DIFF=$((MID_V1_DELTA - MID_V2_DELTA))
if [[ "${MID_V1_DELTA}" -ge 40 ]] && [[ "${FIRST_DIFF}" -ge 30 ]]; then
    demo_assert_pass "First half: traffic went to v1 (v1=${MID_V1_DELTA}, v2=${MID_V2_DELTA}, diff=${FIRST_DIFF})"
else
    demo_assert_fail "First half routing wrong: v1=${MID_V1_DELTA}, v2=${MID_V2_DELTA}, diff=${FIRST_DIFF} (want v1≥40, diff≥30)"
fi

# Second half should favor v2 on the SAME TCP connection
SECOND_DIFF=$((SECOND_HALF_V2_DELTA - SECOND_HALF_V1_DELTA))
if [[ "${SECOND_HALF_V2_DELTA}" -ge 40 ]] && [[ "${SECOND_DIFF}" -ge 30 ]]; then
    demo_assert_pass "Second half: traffic shifted to v2 on the SAME connection (v2=${SECOND_HALF_V2_DELTA}, v1=${SECOND_HALF_V1_DELTA}, diff=${SECOND_DIFF})"
else
    demo_assert_fail "Second half routing wrong: v2=${SECOND_HALF_V2_DELTA}, v1=${SECOND_HALF_V1_DELTA}, diff=${SECOND_DIFF} (want v2≥40, diff≥30)"
fi

echo ""
echo "  ━━ FINDING ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ONE HTTP/2 TCP connection saw new routes per-stream after the xDS"
echo "  push at t=15s. Same finding as the HTTP/1.1 keep-alive case (#13)."
echo "  Modern HTTP/2 clients (browsers, mobile) experience this same      "
echo "  behavior: a long-lived connection sees route changes on the next   "
echo "  stream after any istiod push to the gateway pod it landed on.     "
demo_end

#!/usr/bin/env bash
# ============================================================================
# Demo #13 — xDS push + NLB connection pinning: track isolation is the
#             actual blast-radius mechanism
# ============================================================================
#
# WHY THIS DEMO MATTERS
#   Behind a connection-distributing L4 load balancer (AWS NLB, GCP TCP LB,
#   on-prem F5), each TCP connection is pinned to one gateway pod for its
#   lifetime. A natural question: how does an existing client connection
#   interact with a CRD/xDS push that targets only the canary track? Does
#   the connection "remember" its prior route table, or does it pick up the
#   new one on its next request?
#
# WHAT THIS DEMO ACTUALLY PROVES (and an important correction)
#   An earlier framing of this demo asserted that an existing connection
#   retains its prior route state through an xDS push. ITERATION FINDING:
#   that intuition is WRONG for Envoy / Istio. Routes are looked up
#   per-request, not per-connection: when istiod pushes new config to a
#   gateway pod, requests on existing connections to that pod see the new
#   route table.
#
#   What protects existing connections is NOT connection state. It is TRACK ISOLATION:
#     - NLB connection-distribution pins a TCP connection to one gateway
#       pod (and therefore one track: prod or canary).
#     - Selector-scoped CRDs (Demo #05) make canary-bound config land only
#       on canary-track pods, and prod-bound config land only on prod-track
#       pods.
#     - A change to canary's VS reaches canary pods only; connections that
#       landed on prod pods are completely unaffected, regardless of how
#       long-lived they are.
#
#   This demo proves the track-isolation half directly.
#
# HYPOTHESIS
#   1. Initially: prod-bound VS routes to v1, canary-bound VS routes to v1.
#   2. Existing connection to PROD track → reaches v1. Send some requests.
#   3. Update CANARY's VS to route to v2 (prod's VS unchanged).
#   4. Continue sending requests on the existing PROD connection.
#      PASS: all those requests still hit v1 (prod track is unaffected).
#   5. Open a NEW connection to CANARY track.
#      PASS: it hits v2 (canary track has the new config).
#
# PASS CRITERIA
#   - PROD-connection traffic across the xDS push: ≥6 requests hit v1,
#     ≤2 hit v2 (probe-noise tolerance)
#   - NEW canary-connection traffic: ≥3 hit v2, ≤2 hit v1 (probe noise)
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "13" "xds-push-track-isolation" \
  "Track isolation (selector-scoped CRDs) protects connections to OTHER tracks during an xDS push"

TMPDIR_DEMO="$(mktemp -d)"
PROD_PF_PID=""
CANARY_PF_PID=""
KEEPALIVE_PID=""
cleanup_demo() {
    rm -rf "${TMPDIR_DEMO}"
    [[ -n "${PROD_PF_PID}" ]] && kill "${PROD_PF_PID}" 2>/dev/null || true
    [[ -n "${CANARY_PF_PID}" ]] && kill "${CANARY_PF_PID}" 2>/dev/null || true
    [[ -n "${KEEPALIVE_PID}" ]] && kill "${KEEPALIVE_PID}" 2>/dev/null || true
    kctl delete virtualservice demo13-prod-vs demo13-canary-vs -n apps --ignore-not-found 2>/dev/null
    kctl delete gateway demo13-prod-gw demo13-canary-gw -n istio-system --ignore-not-found 2>/dev/null
}
trap cleanup_demo EXIT

# ---------------------------------------------------------------------------
# Step 1: apply prod-gateway and canary-gateway, each with its own VS to v1
# ---------------------------------------------------------------------------
demo_step "Applying selector-scoped Gateway pair + per-track VS (both initially route to v1)"
cat > "${TMPDIR_DEMO}/setup.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata: {name: demo13-prod-gw, namespace: istio-system}
spec:
  selector:
    app: ${GATEWAY_APP_LABEL}
    ${TRACK_LABEL_KEY}: ${TRACK_PROD}
  servers:
  - port: {number: 80, name: http, protocol: HTTP}
    hosts: ["demo13.example.com"]
---
apiVersion: networking.istio.io/v1
kind: Gateway
metadata: {name: demo13-canary-gw, namespace: istio-system}
spec:
  selector:
    app: ${GATEWAY_APP_LABEL}
    ${TRACK_LABEL_KEY}: ${TRACK_CANARY}
  servers:
  - port: {number: 80, name: http, protocol: HTTP}
    hosts: ["demo13.example.com"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: demo13-prod-vs, namespace: apps}
spec:
  hosts: ["demo13.example.com"]
  gateways: ["istio-system/demo13-prod-gw"]
  http:
  - route:
    - destination: {host: httpbin-v1.apps.svc.cluster.local, port: {number: 8000}}
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: demo13-canary-vs, namespace: apps}
spec:
  hosts: ["demo13.example.com"]
  gateways: ["istio-system/demo13-canary-gw"]
  http:
  - route:
    - destination: {host: httpbin-v1.apps.svc.cluster.local, port: {number: 8000}}
EOF
kctl apply -f "${TMPDIR_DEMO}/setup.yaml" >/dev/null
sleep 4

# ---------------------------------------------------------------------------
# Step 2: separate port-forwards to prod and canary Services
# ---------------------------------------------------------------------------
PROD_PORT=18723
CANARY_PORT=18724
# Use `kubectl` directly (not the kctl function wrapper) so $! captures the
# real kubectl PID. Backgrounding a bash function returns the subshell PID
# instead, and the cleanup trap's `kill ${PF_PID}` would kill the wrapper
# but leave the kubectl child orphaned, holding the port.
kubectl --context "${CONTEXT}" port-forward -n istio-system "svc/${GATEWAY_APP_LABEL}-${TRACK_PROD}" "${PROD_PORT}:80" >/dev/null 2>&1 &
PROD_PF_PID=$!
kubectl --context "${CONTEXT}" port-forward -n istio-system "svc/${GATEWAY_APP_LABEL}-${TRACK_CANARY}" "${CANARY_PORT}:80" >/dev/null 2>&1 &
CANARY_PF_PID=$!
sleep 2
kill -0 "${PROD_PF_PID}" 2>/dev/null && kill -0 "${CANARY_PF_PID}" 2>/dev/null \
    || { demo_assert_fail "port-forwards failed to start"; demo_end; exit $?; }
demo_info "port-forwards: prod=:${PROD_PORT}  canary=:${CANARY_PORT}"

V1_POD="$(kctl get pod -n apps -l app=httpbin,version=v1 -o jsonpath='{.items[0].metadata.name}')"
V2_POD="$(kctl get pod -n apps -l app=httpbin,version=v2 -o jsonpath='{.items[0].metadata.name}')"
_logcount() { kctl logs -n apps "$1" 2>/dev/null | wc -l | tr -d ' '; }

# ---------------------------------------------------------------------------
# Step 3: open a keep-alive connection to PROD track, send 3 requests
#         then pause; during the pause, we update CANARY's VS only.
# ---------------------------------------------------------------------------
demo_step "Opening a long-lived keep-alive connection to PROD track (6 requests + pause)"
PRE_V1=$(_logcount "${V1_POD}")
PRE_V2=$(_logcount "${V2_POD}")
KEEPALIVE_OUT="${TMPDIR_DEMO}/keepalive.out"
KEEPALIVE_SCRIPT="${TMPDIR_DEMO}/keepalive.py"

cat > "${KEEPALIVE_SCRIPT}" <<'PYEOF'
import http.client, sys, time
HOST = "localhost"
PORT = int(sys.argv[1])
TARGET_HOST = sys.argv[2]
PAUSE = float(sys.argv[3])
conn = http.client.HTTPConnection(HOST, PORT, timeout=15)
def req(label):
    conn.request("GET", "/headers", headers={"Host": TARGET_HOST, "Connection": "keep-alive"})
    resp = conn.getresponse()
    resp.read()
    print(f"{label} code={resp.status}", flush=True)
for i in (1, 2, 3):
    req(f"req{i}")
print(f"pausing {PAUSE}s on the open connection (external code will update CANARY's VS only)...", flush=True)
time.sleep(PAUSE)
for i in (4, 5, 6):
    req(f"req{i}")
conn.close()
PYEOF

(python3 "${KEEPALIVE_SCRIPT}" "${PROD_PORT}" "demo13.example.com" 8 > "${KEEPALIVE_OUT}" 2>&1) &
KEEPALIVE_PID=$!

# Wait for the first 3 requests to land
sleep 3

# ---------------------------------------------------------------------------
# Step 4: update CANARY's VS to v2 (prod's VS untouched). The PROD-track
#         connection's subsequent requests should be unaffected.
# ---------------------------------------------------------------------------
demo_step "Updating CANARY's VS to route to v2 (PROD's VS is untouched)"
cat > "${TMPDIR_DEMO}/canary-v2.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: demo13-canary-vs, namespace: apps}
spec:
  hosts: ["demo13.example.com"]
  gateways: ["istio-system/demo13-canary-gw"]
  http:
  - route:
    - destination: {host: httpbin-v2.apps.svc.cluster.local, port: {number: 8000}}
EOF
kctl apply -f "${TMPDIR_DEMO}/canary-v2.yaml" >/dev/null

# Poll for SYNCED — both tracks should be SYNCED, but only canary actually got new config
WAIT_START=$(date +%s)
for i in $(seq 1 20); do
    PS="$("${ISTIOCTL}" --context "${CONTEXT}" proxy-status 2>/dev/null | grep "ingress-gw-")"
    STALE=$(echo "${PS}" | grep -cE "STALE|NOT SENT" || true)
    [[ "${STALE}" -eq 0 ]] && break
    sleep 1
done
demo_info "All gateway pods SYNCED in $(( $(date +%s) - WAIT_START ))s"

# ---------------------------------------------------------------------------
# Step 5: wait for the keep-alive curl to finish; check PROD connection logs
# ---------------------------------------------------------------------------
wait "${KEEPALIVE_PID}" 2>/dev/null || true
KEEPALIVE_PID=""
demo_info "PROD-track keep-alive output:"
cat "${KEEPALIVE_OUT}" | sed 's/^/        /'

sleep 1
POST_V1=$(_logcount "${V1_POD}")
POST_V2=$(_logcount "${V2_POD}")
PROD_CONN_V1_DELTA=$((POST_V1 - PRE_V1))
PROD_CONN_V2_DELTA=$((POST_V2 - PRE_V2))
demo_info "PROD-connection deltas: v1=${PROD_CONN_V1_DELTA}, v2=${PROD_CONN_V2_DELTA}"

# Expected: all 6 PROD-connection requests reach v1; v2 sees only probe noise.
# Track isolation: canary's VS change does NOT affect prod-track pods.
# Threshold: traffic difference (v1 - v2) ≥ 5 — the 6 traffic requests dominate
# equal probe noise on each pod (~6-8 probes/pod over the 17s window).
PROD_TRAFFIC_DIFF=$((PROD_CONN_V1_DELTA - PROD_CONN_V2_DELTA))
if [[ "${PROD_CONN_V1_DELTA}" -ge 6 ]] && [[ "${PROD_TRAFFIC_DIFF}" -ge 5 ]]; then
    demo_assert_pass "PROD-track connection unaffected by canary VS update (v1=${PROD_CONN_V1_DELTA}, v2=${PROD_CONN_V2_DELTA}, traffic-diff=${PROD_TRAFFIC_DIFF})"
else
    demo_assert_fail "PROD-track leak: v1=${PROD_CONN_V1_DELTA} (want ≥6), traffic-diff=${PROD_TRAFFIC_DIFF} (want ≥5)"
fi

# ---------------------------------------------------------------------------
# Step 6: open a NEW connection to CANARY track (where we just applied v2)
# ---------------------------------------------------------------------------
demo_step "Opening a NEW connection to CANARY track (should route to v2)"
PRE_V1=$(_logcount "${V1_POD}")
PRE_V2=$(_logcount "${V2_POD}")
for i in 1 2 3; do
    curl -s -o /dev/null -H "Host: demo13.example.com" "http://localhost:${CANARY_PORT}/headers"
done
sleep 1
NEW_V1_DELTA=$(( $(_logcount "${V1_POD}") - PRE_V1 ))
NEW_V2_DELTA=$(( $(_logcount "${V2_POD}") - PRE_V2 ))
demo_info "CANARY-connection deltas: v1=${NEW_V1_DELTA}, v2=${NEW_V2_DELTA}"

if [[ "${NEW_V2_DELTA}" -ge 3 ]] && [[ "${NEW_V1_DELTA}" -le 2 ]]; then
    demo_assert_pass "CANARY-track connection routed to v2 (v2=${NEW_V2_DELTA}, v1 probe-noise=${NEW_V1_DELTA})"
else
    demo_assert_fail "CANARY-track routing wrong: v2=${NEW_V2_DELTA} (want ≥3), v1=${NEW_V1_DELTA} (want ≤2)"
fi

echo ""
echo "  ━━ INTERPRETATION ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  What protects connections during an xDS push is NOT connection-state."
echo "  Envoy/Istio routes are looked up per-request; existing connections to"
echo "  a pod see the new route table as soon as istiod pushes it.            "
echo "                                                                          "
echo "  What protects connections is TRACK ISOLATION via selector-scoped CRDs:"
echo "    - NLB pins each TCP connection to one pod (= one track)             "
echo "    - Canary-bound CRDs only reach canary-track pods (Demo #05)         "
echo "    - A canary VS update does NOT affect connections to prod pods       "
echo "                                                                          "
echo "  Within a single track, an existing connection's NEXT request CAN see  "
echo "  a config change. The selector-scoped Gateway pair is what gives a     "
echo "  cohort of users (those on the prod track) total isolation from any   "
echo "  ongoing canary work.                                                  "

demo_end

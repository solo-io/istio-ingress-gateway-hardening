#!/usr/bin/env bash
# ============================================================================
# Demo #12 — Envoy listener warming gracefully degrades a bad listener push
# ============================================================================
#
# HYPOTHESIS
#   Envoy's default listener warming behavior: a new listener config that
#   fails to bind or initialize does NOT replace the previously-working
#   listener. The gateway pod's previous listener continues to serve
#   traffic while the new listener stays in "warming" state and never
#   transitions to "active". The customer sees "feature didn't deploy"
#   rather than "ingress dropped traffic."
#
#   To demonstrate: stand up a working Gateway on port 80, send traffic,
#   confirm it works. Then apply a SECOND Gateway resource attempting to
#   bind the same port 80 with a conflicting TLS setting. Verify the
#   original listener keeps serving and the new listener fails to warm.
#
# SETUP / ACTION / VERIFICATION
#   1. Apply demo12-gw-a (port 80, HTTP) and VS routing to httpbin
#   2. Send 5 baseline requests through canary-gateway; all 200
#   3. Apply demo12-gw-b ALSO targeting canary track at port 80 with
#      conflicting HTTPS protocol (port conflict with HTTP listener)
#   4. Wait briefly for istiod to attempt the push
#   5. Send 5 more requests through canary-gateway; assert all still 200
#   6. Inspect `istioctl pc listeners` and confirm port 80 is still
#      serving HTTP (not replaced by the failing config)
#
# PASS criterion
#   - Pre-conflict traffic: 5/5 200 OK
#   - Post-conflict traffic: 5/5 200 OK (existing listener still serving)
#   - Listener summary shows the original :80 HTTP listener still present
#
# PRODUCT-IMPROVEMENT NOTE
#   This graceful-degradation behavior is Envoy's default but is rarely
#   documented in Solo / Istio operator-facing material. A docs page on
#   "what gracefully degrades and what doesn't during a bad xDS push to a
#   gateway" would surface the behaviors operators can rely on.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "12" "envoy-listener-warming" \
  "Bad listener config doesn't replace the working listener; existing traffic continues"

TMPDIR_DEMO="$(mktemp -d)"
PF_PID=""
cleanup_demo() {
    rm -rf "${TMPDIR_DEMO}"
    [[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true
    kctl delete virtualservice demo12-vs -n apps --ignore-not-found 2>/dev/null
    kctl delete gateway demo12-gw-a demo12-gw-b -n istio-system --ignore-not-found 2>/dev/null
}
trap cleanup_demo EXIT

# ---------------------------------------------------------------------------
# Step 1: working baseline (Gateway A on port 80, VS to httpbin)
# ---------------------------------------------------------------------------
demo_step "Applying working baseline: demo12-gw-a (port 80 HTTP) + demo12-vs → httpbin"
cat > "${TMPDIR_DEMO}/baseline.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: demo12-gw-a
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
    hosts: ["demo12.example.com"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: demo12-vs
  namespace: apps
spec:
  hosts: ["demo12.example.com"]
  gateways: ["istio-system/demo12-gw-a"]
  http:
  - route:
    - destination:
        host: httpbin.apps.svc.cluster.local
        port:
          number: 8000
EOF
kctl apply -f "${TMPDIR_DEMO}/baseline.yaml" >/dev/null
wait_until_synced "ingress-gw-${TRACK_CANARY}" 30 || true

LOCAL_PORT=18712
PF_PID="$(start_port_forward "${SYSTEM_NS}" "svc/${GATEWAY_APP_LABEL}-${TRACK_CANARY}" "${LOCAL_PORT}:80")" \
    || { demo_assert_fail "port-forward died"; demo_end; exit $?; }

# Send 5 baseline requests
demo_step "Sending 5 baseline requests via canary gateway (expect all 200)"
PRE_CODES=""
for i in 1 2 3 4 5; do
    CODE="$(curl -s -o /dev/null -w "%{http_code}" -H "Host: demo12.example.com" "http://localhost:${LOCAL_PORT}/headers")"
    PRE_CODES="${PRE_CODES} ${CODE}"
done
demo_info "Pre-conflict codes:${PRE_CODES}"
PRE_NON_200=$(echo "${PRE_CODES}" | tr ' ' '\n' | awk 'NF && $1 != "200"' | wc -l | tr -d ' ')
if [[ "${PRE_NON_200}" -eq 0 ]]; then
    demo_assert_pass "Baseline: 5/5 requests served 200 OK"
else
    demo_assert_fail "Baseline broken before conflict applied; ${PRE_NON_200}/5 non-200"
    demo_end
    exit $?
fi

# Capture original listener summary for post-conflict comparison
demo_step "Capturing baseline listener summary on a canary pod"
CANARY_POD="$(kctl get pod -n istio-system -l "app=${GATEWAY_APP_LABEL},${TRACK_LABEL_KEY}=${TRACK_CANARY}" -o jsonpath='{.items[0].metadata.name}')"
# Gateway pod listens on :8080 (Service maps 80 → 8080)
LISTENERS_BEFORE="$("${ISTIOCTL}" --context "${CONTEXT}" pc listeners "${CANARY_POD}.istio-system" 2>/dev/null | awk '/^0\.0\.0\.0[[:space:]]+8080/')"
demo_info "Baseline listener for :8080 →"
echo "${LISTENERS_BEFORE}" | sed 's/^/        /'

# ---------------------------------------------------------------------------
# Step 2: introduce conflicting Gateway B on the same port 80 with HTTPS
# ---------------------------------------------------------------------------
demo_step "Applying CONFLICTING Gateway demo12-gw-b: same port 80, HTTPS (TLS required)"
cat > "${TMPDIR_DEMO}/conflict.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: demo12-gw-b
  namespace: istio-system
spec:
  selector:
    app: ${GATEWAY_APP_LABEL}
    ${TRACK_LABEL_KEY}: ${TRACK_CANARY}
  servers:
  - port:
      number: 80
      name: https-conflict
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: nonexistent-cert  # never provisioned; TLS will fail
    hosts: ["demo12.example.com"]
EOF
kctl apply -f "${TMPDIR_DEMO}/conflict.yaml" >/dev/null
sleep 6  # let istiod attempt the push

# ---------------------------------------------------------------------------
# Step 3: post-conflict, traffic should still flow on the original listener
# ---------------------------------------------------------------------------
demo_step "Sending 5 more requests AFTER conflict applied (expect all still 200)"
POST_CODES=""
for i in 1 2 3 4 5; do
    CODE="$(curl -s -o /dev/null -w "%{http_code}" -H "Host: demo12.example.com" "http://localhost:${LOCAL_PORT}/headers" --max-time 5)"
    POST_CODES="${POST_CODES} ${CODE}"
done
demo_info "Post-conflict codes:${POST_CODES}"
POST_NON_200=$(echo "${POST_CODES}" | tr ' ' '\n' | awk 'NF && $1 != "200"' | wc -l | tr -d ' ')
if [[ "${POST_NON_200}" -eq 0 ]]; then
    demo_assert_pass "Post-conflict: 5/5 requests STILL served 200 OK (existing listener intact)"
else
    demo_assert_fail "Post-conflict: ${POST_NON_200}/5 non-200; ingress traffic was disrupted by the bad push"
fi

# ---------------------------------------------------------------------------
# Step 4: listener summary should still show :80 HTTP listener
# ---------------------------------------------------------------------------
demo_step "Inspecting listener state after conflicting push"
LISTENERS_AFTER="$("${ISTIOCTL}" --context "${CONTEXT}" pc listeners "${CANARY_POD}.istio-system" 2>/dev/null | awk '/^0\.0\.0\.0[[:space:]]+8080/')"
demo_info "Listener for :8080 after conflict →"
echo "${LISTENERS_AFTER}" | sed 's/^/        /'

# The original HTTP listener routes to http.8080. Confirm that route is still
# the destination (the bad HTTPS config did not replace it).
if echo "${LISTENERS_AFTER}" | grep -qiE "Route: http\.8080|http\.8080$"; then
    demo_assert_pass "Port :8080 listener still routes to http.8080 (bad HTTPS push did not replace it)"
else
    demo_assert_fail "Port :8080 listener does NOT show the original Route: http.8080; conflicting config may have taken effect"
fi

demo_end

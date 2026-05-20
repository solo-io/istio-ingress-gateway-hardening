#!/usr/bin/env bash
# ============================================================================
# Demo #09b — Header-matched canary (Kubernetes Gateway API)
# ============================================================================
#
# HYPOTHESIS
#   An HTTPRoute with two rules — one whose `matches[].headers` lists
#   `x-canary: true`, one default — routes header-marked traffic to
#   httpbin-v2 and default traffic to httpbin-v1. More-specific matches
#   win, same as the classic Istio API (Demo #09a).
#
# PARITY NOTE (intentional contrast with #09a)
#   Both APIs land cleanly here. No parity gap to report; this is the
#   side-by-side that lets a team pick whichever API surface suits them
#   without losing functionality.
#
# SETUP / VERIFICATION / PASS
#   Same shape as #09a, using Gateway API resources and log-delta routing
#   verification.
#
# WHY THE "≤2 probe-noise" THRESHOLD
#   httpbin's readinessProbe is configured with periodSeconds: 2 in deploy.sh.
#   Over a 5-second test window, each pod naturally receives ~2-3 probe hits
#   that ALSO get logged. Asserting "other backend received 0 requests" would
#   produce false failures. Tolerating up to 2 probe hits on the unintended
#   backend correctly separates traffic-leakage from probe-noise.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "09b" "header-matched-canary-gwapi" \
  "HTTPRoute header-matched rule directs x-canary traffic to v2, default to v1"

TMPDIR_DEMO="$(mktemp -d)"
PF_PID=""
cleanup_demo() {
    rm -rf "${TMPDIR_DEMO}"
    [[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true
    kctl delete httproute demo09b-route -n apps --ignore-not-found 2>/dev/null
    kctl delete gateway.gateway.networking.k8s.io demo09b-gw -n apps --ignore-not-found 2>/dev/null
}
trap cleanup_demo EXIT

demo_step "Applying Gateway API Gateway + HTTPRoute (header→v2, default→v1)"
cat > "${TMPDIR_DEMO}/manifests.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: demo09b-gw
  namespace: apps
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: "demo09b.example.com"
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: demo09b-route
  namespace: apps
spec:
  parentRefs:
  - name: demo09b-gw
  hostnames:
  - "demo09b.example.com"
  rules:
  # More-specific match wins; Gateway API's spec mandates this ordering rule
  - matches:
    - headers:
      - name: x-canary
        value: "true"
    backendRefs:
    - name: httpbin-v2
      port: 8000
  - backendRefs:
    - name: httpbin-v1
      port: 8000
EOF
kctl apply -f "${TMPDIR_DEMO}/manifests.yaml" >/dev/null

demo_step "Waiting for Istio to provision the backing Deployment..."
for i in $(seq 1 60); do
    READY=$(kctl get deployment demo09b-gw-istio -n apps -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${READY:-0}" -ge 1 ]]; then
        demo_info "demo09b-gw-istio Deployment ready"
        break
    fi
    sleep 1
done
[[ "${READY:-0}" -lt 1 ]] && { demo_assert_fail "Istio did not provision backing pod in 60s"; demo_end; exit $?; }
sleep 3

LOCAL_PORT=18692
# Use `kubectl` directly (not the kctl function wrapper) so $! captures the
# real kubectl PID. Backgrounding a bash function returns the subshell PID
# instead, and the cleanup trap's `kill ${PF_PID}` would kill the wrapper
# but leave the kubectl child orphaned, holding the port.
kubectl --context "${CONTEXT}" port-forward -n apps "svc/demo09b-gw-istio" "${LOCAL_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
sleep 2
kill -0 "${PF_PID}" 2>/dev/null || { demo_assert_fail "port-forward died"; demo_end; exit $?; }

V1_POD="$(kctl get pod -n apps -l app=httpbin,version=v1 -o jsonpath='{.items[0].metadata.name}')"
V2_POD="$(kctl get pod -n apps -l app=httpbin,version=v2 -o jsonpath='{.items[0].metadata.name}')"
demo_info "v1 pod: ${V1_POD}"
demo_info "v2 pod: ${V2_POD}"

_logcount() { kctl logs -n apps "$1" 2>/dev/null | wc -l | tr -d ' '; }

# ---------------------------------------------------------------------------
# Round 1: default-traffic (no header) → expect v1
# ---------------------------------------------------------------------------
demo_step "Sending 5 requests WITHOUT x-canary header (expect routing to v1)"
PRE_V1=$(_logcount "${V1_POD}")
PRE_V2=$(_logcount "${V2_POD}")
for i in 1 2 3 4 5; do
    curl -s -o /dev/null -H "Host: demo09b.example.com" "http://localhost:${LOCAL_PORT}/headers"
done
sleep 1
V1_DELTA=$(( $(_logcount "${V1_POD}") - PRE_V1 ))
V2_DELTA=$(( $(_logcount "${V2_POD}") - PRE_V2 ))
demo_info "default-traffic deltas: v1=${V1_DELTA}  v2=${V2_DELTA}"
if [[ "${V1_DELTA}" -ge 5 ]] && [[ "${V2_DELTA}" -le 2 ]]; then
    demo_assert_pass "Default-traffic routed to v1 (v1=${V1_DELTA}, v2≤2 probe-noise)"
else
    demo_assert_fail "Default-traffic routing wrong: v1=${V1_DELTA} (want ≥5), v2=${V2_DELTA} (want ≤2)"
fi

# ---------------------------------------------------------------------------
# Round 2: canary-header → expect v2
# ---------------------------------------------------------------------------
demo_step "Sending 5 requests WITH x-canary: true (expect routing to v2)"
PRE_V1=$(_logcount "${V1_POD}")
PRE_V2=$(_logcount "${V2_POD}")
for i in 1 2 3 4 5; do
    curl -s -o /dev/null -H "Host: demo09b.example.com" -H "x-canary: true" "http://localhost:${LOCAL_PORT}/headers"
done
sleep 1
V1_DELTA=$(( $(_logcount "${V1_POD}") - PRE_V1 ))
V2_DELTA=$(( $(_logcount "${V2_POD}") - PRE_V2 ))
demo_info "canary-traffic deltas: v1=${V1_DELTA}  v2=${V2_DELTA}"
if [[ "${V2_DELTA}" -ge 5 ]] && [[ "${V1_DELTA}" -le 2 ]]; then
    demo_assert_pass "Canary-header traffic routed to v2 (v2=${V2_DELTA}, v1≤2 probe-noise)"
else
    demo_assert_fail "Canary-traffic routing wrong: v2=${V2_DELTA} (want ≥5), v1=${V1_DELTA} (want ≤2)"
fi

demo_end

#!/usr/bin/env bash
# ============================================================================
# Demo #09a — Header-matched canary (classic Istio API)
# ============================================================================
#
# HYPOTHESIS
#   A VirtualService with two http rules — one matching `x-canary: true`,
#   one default — routes header-marked traffic to httpbin-v2 and default
#   traffic to httpbin-v1. More-specific match wins.
#
# PRACTICAL VALUE
#   Synthetic test traffic carrying a known header can be sent through
#   the real candidate config without user impact. Combine with #08
#   mirroring to validate config behavior under real production payloads
#   plus a small synthetic test corpus.
#
# SETUP / VERIFICATION / PASS
#   - Gateway demo09a-canary-gw + VS demo09a-vs (rules: header→v2, default→v1)
#   - 5 requests without the header → all served by VARIANT=v1
#   - 5 requests with `x-canary: true`  → all served by VARIANT=v2
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "09a" "header-matched-canary-istio" \
  "VirtualService header-matched route directs x-canary traffic to v2, default to v1"

TMPDIR_DEMO="$(mktemp -d)"
PF_PID=""
cleanup_demo() {
    rm -rf "${TMPDIR_DEMO}"
    [[ -n "${PF_PID}" ]] && kill "${PF_PID}" 2>/dev/null || true
    kctl delete virtualservice demo09a-vs -n apps --ignore-not-found 2>/dev/null
    kctl delete gateway demo09a-canary-gw -n istio-system --ignore-not-found 2>/dev/null
}
trap cleanup_demo EXIT

demo_step "Applying Gateway + VS with header→v2, default→v1"
cat > "${TMPDIR_DEMO}/manifests.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: demo09a-canary-gw
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
    hosts: ["demo09a.example.com"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: demo09a-vs
  namespace: apps
spec:
  hosts: ["demo09a.example.com"]
  gateways: ["istio-system/demo09a-canary-gw"]
  http:
  # More-specific rule MUST come first
  - match:
    - headers:
        x-canary:
          exact: "true"
    route:
    - destination:
        host: httpbin-v2.apps.svc.cluster.local
        port:
          number: 8000
  - route:
    - destination:
        host: httpbin-v1.apps.svc.cluster.local
        port:
          number: 8000
EOF
kctl apply -f "${TMPDIR_DEMO}/manifests.yaml" >/dev/null
wait_until_synced "ingress-gw-${TRACK_CANARY}" 30 || true

LOCAL_PORT=18691
PF_PID="$(start_port_forward "${SYSTEM_NS}" "svc/${GATEWAY_APP_LABEL}-${TRACK_CANARY}" "${LOCAL_PORT}:80")" \
    || { demo_assert_fail "port-forward died"; demo_end; exit $?; }

V1_POD="$(kctl get pod -n apps -l app=httpbin,version=v1 -o jsonpath='{.items[0].metadata.name}')"
V2_POD="$(kctl get pod -n apps -l app=httpbin,version=v2 -o jsonpath='{.items[0].metadata.name}')"
demo_info "v1 pod: ${V1_POD}"
demo_info "v2 pod: ${V2_POD}"

# Helper: count log lines (httpbin logs every served request).
_logcount() { kctl logs -n apps "$1" 2>/dev/null | wc -l | tr -d ' '; }

# ---------------------------------------------------------------------------
# Round 1: 5 requests WITHOUT the header (expect ALL hit v1)
# ---------------------------------------------------------------------------
demo_step "Sending 5 requests WITHOUT x-canary header (expect ALL to hit v1)"
PRE_V1=$(_logcount "${V1_POD}")
PRE_V2=$(_logcount "${V2_POD}")
for i in 1 2 3 4 5; do
    curl -s -o /dev/null -H "Host: demo09a.example.com" "http://localhost:${LOCAL_PORT}/headers"
done
sleep 1
POST_V1=$(_logcount "${V1_POD}")
POST_V2=$(_logcount "${V2_POD}")
V1_DELTA=$((POST_V1 - PRE_V1))
V2_DELTA=$((POST_V2 - PRE_V2))
demo_info "default-traffic deltas: v1=${V1_DELTA}  v2=${V2_DELTA}"

# Allow up to 2 probe-noise hits on the "other" pod (readiness probe is 2s).
if [[ "${V1_DELTA}" -ge 5 ]] && [[ "${V2_DELTA}" -le 2 ]]; then
    demo_assert_pass "Default-traffic routed to v1 (v1=${V1_DELTA}, v2≤2 probe-noise)"
else
    demo_assert_fail "Default-traffic routing wrong: v1=${V1_DELTA} (want ≥5), v2=${V2_DELTA} (want ≤2 for probe-noise tolerance)"
fi

# ---------------------------------------------------------------------------
# Round 2: 5 requests WITH x-canary: true (expect ALL hit v2)
# ---------------------------------------------------------------------------
demo_step "Sending 5 requests WITH x-canary: true (expect ALL to hit v2)"
PRE_V1=$(_logcount "${V1_POD}")
PRE_V2=$(_logcount "${V2_POD}")
for i in 1 2 3 4 5; do
    curl -s -o /dev/null -H "Host: demo09a.example.com" -H "x-canary: true" "http://localhost:${LOCAL_PORT}/headers"
done
sleep 1
POST_V1=$(_logcount "${V1_POD}")
POST_V2=$(_logcount "${V2_POD}")
V1_DELTA=$((POST_V1 - PRE_V1))
V2_DELTA=$((POST_V2 - PRE_V2))
demo_info "canary-traffic deltas: v1=${V1_DELTA}  v2=${V2_DELTA}"

if [[ "${V2_DELTA}" -ge 5 ]] && [[ "${V1_DELTA}" -le 2 ]]; then
    demo_assert_pass "Canary-header traffic routed to v2 (v2=${V2_DELTA}, v1≤2 probe-noise)"
else
    demo_assert_fail "Canary-traffic routing wrong: v2=${V2_DELTA} (want ≥5), v1=${V1_DELTA} (want ≤2 for probe-noise tolerance)"
fi

demo_end

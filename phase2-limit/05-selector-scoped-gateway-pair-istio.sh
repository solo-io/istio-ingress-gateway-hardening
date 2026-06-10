#!/usr/bin/env bash
# ============================================================================
# Demo #05a — Selector-scoped Gateway pair (classic Istio API)
# ============================================================================
#
# HYPOTHESIS
#   Two Gateway CRs whose `spec.selector` matches disjoint pod label sets
#   (track=prod vs track=canary) cause istiod to push that Gateway's routes
#   ONLY to the matching gateway pods. A VirtualService bound to
#   canary-gateway (via spec.gateways) reaches canary pods only.
#
# SETUP
#   Base already provides ingress-gw-prod (3 replicas, track=prod) and
#   ingress-gw-canary (3 replicas, track=canary) in istio-system.
#
#   This demo creates:
#     - prod-gateway   (selector matches track=prod pods)
#     - canary-gateway (selector matches track=canary pods)
#     - A candidate VirtualService bound to canary-gateway only
#
# ACTION + VERIFICATION
#   Inspect `istioctl pc routes` on a prod pod and a canary pod.
#   PASS:
#     - The candidate route appears on the canary pod
#     - The candidate route is absent from the prod pod
#
# RELEVANCE
#   Centerpiece of the Limit phase. The selector-scoped Gateway pair is the
#   primary blast-radius reduction mechanism for in-place CRD rollouts: it
#   confines a candidate VS/HTTPRoute to a labeled subset of gateway pods.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "05a" "selector-scoped-gateway-pair-istio" \
  "Two Gateway CRs with disjoint selectors route CRDs only to matching gateway pods"

TMPDIR_DEMO="$(mktemp -d)"
cleanup_demo() {
    rm -rf "${TMPDIR_DEMO}"
    kctl delete virtualservice demo05a-canary-vs -n "${APPS_NS}" --ignore-not-found 2>/dev/null
    kctl delete gateway demo05a-prod-gw demo05a-canary-gw -n "${SYSTEM_NS}" --ignore-not-found 2>/dev/null
}
trap cleanup_demo EXIT

# ---------------------------------------------------------------------------
# Step 1: apply prod-gateway and canary-gateway (disjoint selectors)
# ---------------------------------------------------------------------------
demo_step "Applying Gateway CRs with disjoint selectors (prod + canary)"
cat > "${TMPDIR_DEMO}/gateways.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: demo05a-prod-gw
  namespace: istio-system
spec:
  selector:
    app: ${GATEWAY_APP_LABEL}
    ${TRACK_LABEL_KEY}: ${TRACK_PROD}
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts: ["demo05a-prod.example.com"]
---
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: demo05a-canary-gw
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
    hosts: ["demo05a-canary.example.com"]
EOF
kctl apply -f "${TMPDIR_DEMO}/gateways.yaml" >/dev/null
demo_info "Applied: demo05a-prod-gw (selects track=prod), demo05a-canary-gw (selects track=canary)"

# ---------------------------------------------------------------------------
# Step 2: apply a VirtualService bound ONLY to canary-gateway
# ---------------------------------------------------------------------------
demo_step "Applying VirtualService bound only to canary-gateway"
cat > "${TMPDIR_DEMO}/vs.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: demo05a-canary-vs
  namespace: apps
spec:
  hosts: ["demo05a-canary.example.com"]
  gateways: ["istio-system/demo05a-canary-gw"]
  http:
  - route:
    - destination:
        host: httpbin.apps.svc.cluster.local
        port:
          number: 8000
EOF
kctl apply -f "${TMPDIR_DEMO}/vs.yaml" >/dev/null

# Pick the canary pod we'll verify against and poll its pc routes until the
# new VS shows up. proxy-status SYNCED isn't a strong enough signal here:
# right after the apply, istiod's push-debounce window can briefly show
# SYNCED-to-old-state, and the verification below would then race the push.
PROD_POD="$(kctl get pod -n "${SYSTEM_NS}" -l "app=${GATEWAY_APP_LABEL},${TRACK_LABEL_KEY}=${TRACK_PROD}" -o jsonpath='{.items[0].metadata.name}')"
CANARY_POD="$(kctl get pod -n "${SYSTEM_NS}" -l "app=${GATEWAY_APP_LABEL},${TRACK_LABEL_KEY}=${TRACK_CANARY}" -o jsonpath='{.items[0].metadata.name}')"
wait_pc_match "${CANARY_POD}.${SYSTEM_NS}" routes "demo05a-canary.example.com" 30 || true

# ---------------------------------------------------------------------------
# Step 3: inspect routes on the prod pod and the canary pod
# ---------------------------------------------------------------------------
demo_step "Inspecting 'istioctl pc routes' on one prod pod and one canary pod"
demo_info "prod pod:   ${PROD_POD}"
demo_info "canary pod: ${CANARY_POD}"

PROD_ROUTES="$("${ISTIOCTL}" --context "${CONTEXT}" pc routes "${PROD_POD}.${SYSTEM_NS}" 2>/dev/null || true)"
CANARY_ROUTES="$("${ISTIOCTL}" --context "${CONTEXT}" pc routes "${CANARY_POD}.${SYSTEM_NS}" 2>/dev/null || true)"

# Print compact route summaries so the FAIL signal includes context
demo_info "prod pod routes (rows with 'demo05a'):"
echo "${PROD_ROUTES}" | grep -i "demo05a" | sed 's/^/        /' || echo "        (none)"
demo_info "canary pod routes (rows with 'demo05a'):"
echo "${CANARY_ROUTES}" | grep -i "demo05a" | sed 's/^/        /' || echo "        (none)"

# ---------------------------------------------------------------------------
# Step 4: assert canary has the route AND prod does not
# ---------------------------------------------------------------------------
if echo "${CANARY_ROUTES}" | grep -qi "demo05a-canary.example.com"; then
    demo_assert_pass "Candidate route present on canary pod"
else
    demo_assert_fail "Candidate route MISSING from canary pod (CRD didn't reach the right scope)"
fi

if echo "${PROD_ROUTES}" | grep -qi "demo05a-canary.example.com"; then
    demo_assert_fail "Candidate route LEAKED to prod pod (selector scoping broken)"
else
    demo_assert_pass "Candidate route absent from prod pod (scoping confirmed)"
fi

demo_end

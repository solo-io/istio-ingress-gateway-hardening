#!/usr/bin/env bash
# ============================================================================
# Demo #06 — VirtualService.exportTo (classic Istio API)
# ============================================================================
#
# HYPOTHESIS
#   VirtualService.exportTo controls which namespaces can "see and use"
#   the resource. A VirtualService in apps-ns-a bound to a Gateway in
#   istio-system is delivered to the gateway pods when exportTo=["*"]
#   (default), but is NOT delivered when exportTo=["."] (own namespace
#   only) because istio-system is not in the export list.
#
# SETUP
#   - Apply a Gateway demo06-canary-gw in istio-system (selects track=canary)
#   - Apply a VirtualService demo06-vs in apps-ns-a bound to that Gateway
#
# ACTION + VERIFICATION
#   - With exportTo=["*"]: route present on canary gateway pods
#   - Patch exportTo=["."]:  route DISAPPEARS from canary gateway pods
#   - Patch exportTo=["*"] back: route reappears (control case)
#
# PRODUCT-IMPROVEMENT NOTE
#   Gateway API does NOT have a direct exportTo equivalent on routing
#   resources. Closest analogue is `Gateway.spec.listeners[].allowedRoutes.namespaces`
#   on the receiving Gateway, which is a Gateway-side control rather than
#   a resource-side control. Structural parity gap; captured in PLAN.md.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "06" "exportto" \
  "exportTo: ['.'] hides a VS from gateway pods in other namespaces"

TMPDIR_DEMO="$(mktemp -d)"
cleanup_demo() {
    rm -rf "${TMPDIR_DEMO}"
    kctl delete virtualservice demo06-vs -n "${APPS_NS_A}" --ignore-not-found 2>/dev/null
    kctl delete gateway demo06-canary-gw -n istio-system --ignore-not-found 2>/dev/null
}
trap cleanup_demo EXIT

CANARY_POD="$(kctl get pod -n istio-system -l "app=${GATEWAY_APP_LABEL},${TRACK_LABEL_KEY}=${TRACK_CANARY}" -o jsonpath='{.items[0].metadata.name}')"
demo_info "Inspecting canary pod: ${CANARY_POD}"

# ---------------------------------------------------------------------------
# Step 1: Gateway in istio-system + VS in apps-ns-a with exportTo=["*"]
# ---------------------------------------------------------------------------
demo_step "Applying Gateway in istio-system and VirtualService in ${APPS_NS_A} with exportTo=['*']"
cat > "${TMPDIR_DEMO}/manifests.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: demo06-canary-gw
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
    hosts: ["demo06.example.com"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: demo06-vs
  namespace: ${APPS_NS_A}
spec:
  exportTo: ["*"]
  hosts: ["demo06.example.com"]
  gateways: ["istio-system/demo06-canary-gw"]
  http:
  - route:
    - destination:
        host: httpbin.apps.svc.cluster.local
        port:
          number: 8000
EOF
kctl apply -f "${TMPDIR_DEMO}/manifests.yaml" >/dev/null
sleep 4

# ---------------------------------------------------------------------------
# Step 2: assert route is present on canary pod (exportTo=["*"])
# ---------------------------------------------------------------------------
ROUTES="$("${ISTIOCTL}" --context "${CONTEXT}" pc routes "${CANARY_POD}.istio-system" 2>/dev/null || true)"
if echo "${ROUTES}" | grep -qi "demo06.example.com"; then
    demo_assert_pass "With exportTo=['*'], the VS reaches the canary gateway pod"
    demo_info "  match line:"
    echo "${ROUTES}" | grep -i "demo06" | sed 's/^/        /'
else
    demo_assert_fail "Expected VS reachable with exportTo=['*'] but it is missing"
fi

# ---------------------------------------------------------------------------
# Step 3: patch exportTo to ["."]; expect route to disappear from canary pod
# ---------------------------------------------------------------------------
demo_step "Patching VirtualService.spec.exportTo to ['.'] (own namespace only)"
kctl patch virtualservice demo06-vs -n "${APPS_NS_A}" --type=merge -p '{"spec":{"exportTo":["."]}}' >/dev/null
sleep 4

ROUTES="$("${ISTIOCTL}" --context "${CONTEXT}" pc routes "${CANARY_POD}.istio-system" 2>/dev/null || true)"
if echo "${ROUTES}" | grep -qi "demo06.example.com"; then
    demo_assert_fail "After exportTo=['.'], route still present on canary pod (visibility scoping failed)"
    echo "${ROUTES}" | grep -i "demo06" | sed 's/^/        /'
else
    demo_assert_pass "After exportTo=['.'], route absent from canary gateway pod (cross-namespace visibility blocked)"
fi

# ---------------------------------------------------------------------------
# Step 4: revert exportTo back to ["*"]; route should reappear (control case)
# ---------------------------------------------------------------------------
demo_step "Reverting exportTo back to ['*'] (control: route should reappear)"
kctl patch virtualservice demo06-vs -n "${APPS_NS_A}" --type=merge -p '{"spec":{"exportTo":["*"]}}' >/dev/null
sleep 4

ROUTES="$("${ISTIOCTL}" --context "${CONTEXT}" pc routes "${CANARY_POD}.istio-system" 2>/dev/null || true)"
if echo "${ROUTES}" | grep -qi "demo06.example.com"; then
    demo_assert_pass "After reverting exportTo=['*'], route reappears (scoping is reversible)"
else
    demo_assert_fail "After reverting exportTo=['*'], route did not reappear"
fi

demo_end

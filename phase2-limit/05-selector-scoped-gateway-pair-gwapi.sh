#!/usr/bin/env bash
# ============================================================================
# Demo #05b — Selector-scoped Gateway pair (Kubernetes Gateway API)
# ============================================================================
#
# HYPOTHESIS
#   The Gateway API achieves the same scoping outcome as the classic Istio
#   API selector pair, BUT via a structurally different mechanic. With
#   gatewayClassName=istio, Istio auto-provisions a backing Deployment per
#   Gateway. An HTTPRoute is then scoped by `parentRefs` to one Gateway only.
#
#   The route appears on the matching Gateway's auto-provisioned pods and
#   NOT on the other Gateway's pods. Same blast-radius behavior as #05a,
#   different underlying primitive.
#
# SETUP
#   Apply two Gateway API resources (prod + canary). Wait for Istio to
#   auto-provision <gateway-name>-istio Deployments. Apply an HTTPRoute
#   with parentRefs only to the canary Gateway.
#
# ACTION + VERIFICATION
#   `istioctl pc routes` on a prod-Gateway-provisioned pod vs. canary's.
#   PASS:
#     - Route present on canary-Gateway-provisioned pod
#     - Route absent from prod-Gateway-provisioned pod
#
# PRODUCT-IMPROVEMENT NOTE
#   The Gateway API uses per-listener `allowedRoutes` semantics rather than
#   workload selectors. Same outcome reached differently; the cross-API
#   parity story for scoping primitives is worth a docs page so migrators
#   know what changes and what doesn't.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "05b" "selector-scoped-gateway-pair-gwapi" \
  "Gateway API: HTTPRoute parentRefs route CRD only to the matching Gateway's pods"

TMPDIR_DEMO="$(mktemp -d)"
cleanup_demo() {
    rm -rf "${TMPDIR_DEMO}"
    kctl delete httproute demo05b-canary-route -n apps --ignore-not-found 2>/dev/null
    kctl delete gateway.gateway.networking.k8s.io demo05b-prod-gw demo05b-canary-gw -n apps --ignore-not-found 2>/dev/null
}
trap cleanup_demo EXIT

# ---------------------------------------------------------------------------
# Step 1: apply two Gateway API resources (Istio auto-provisions backing pods)
# ---------------------------------------------------------------------------
demo_step "Applying two Gateway API Gateways (Istio will auto-provision backing Deployments)"
cat > "${TMPDIR_DEMO}/gateways.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: demo05b-prod-gw
  namespace: apps
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: "demo05b-prod.example.com"
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: demo05b-canary-gw
  namespace: apps
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: "demo05b-canary.example.com"
    allowedRoutes:
      namespaces:
        from: Same
EOF
kctl apply -f "${TMPDIR_DEMO}/gateways.yaml" >/dev/null

# ---------------------------------------------------------------------------
# Step 2: wait for Istio to provision the backing Deployments
# ---------------------------------------------------------------------------
demo_step "Waiting for Istio to provision backing Deployments..."
for i in $(seq 1 60); do
    PROD_READY=$(kctl get deployment demo05b-prod-gw-istio -n apps -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    CANARY_READY=$(kctl get deployment demo05b-canary-gw-istio -n apps -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${PROD_READY:-0}" -ge 1 ]] && [[ "${CANARY_READY:-0}" -ge 1 ]]; then
        demo_info "Both Gateway-API-provisioned Deployments ready (prod=${PROD_READY}, canary=${CANARY_READY})"
        break
    fi
    sleep 1
done
if [[ "${PROD_READY:-0}" -lt 1 ]] || [[ "${CANARY_READY:-0}" -lt 1 ]]; then
    demo_assert_fail "Istio did not provision Gateway-API backing pods within 60s (prod=${PROD_READY:-0}, canary=${CANARY_READY:-0})"
    demo_end
    exit $?
fi

# ---------------------------------------------------------------------------
# Step 3: apply HTTPRoute bound only to canary Gateway via parentRefs
# ---------------------------------------------------------------------------
demo_step "Applying HTTPRoute with parentRefs only to canary Gateway"
cat > "${TMPDIR_DEMO}/route.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: demo05b-canary-route
  namespace: apps
spec:
  parentRefs:
  - name: demo05b-canary-gw
  hostnames:
  - "demo05b-canary.example.com"
  rules:
  - backendRefs:
    - name: httpbin
      port: 8000
EOF
kctl apply -f "${TMPDIR_DEMO}/route.yaml" >/dev/null

# Wait for istiod to push to the auto-provisioned gateway pods (both prod + canary).
wait_until_synced "demo05b-" 30 || true

# ---------------------------------------------------------------------------
# Step 4: inspect routes on each Gateway-API-provisioned pod
# ---------------------------------------------------------------------------
demo_step "Inspecting 'istioctl pc routes' on the two auto-provisioned gateway pods"
PROD_POD="$(kctl get pod -n apps -l "gateway.networking.k8s.io/gateway-name=demo05b-prod-gw" -o jsonpath='{.items[0].metadata.name}')"
CANARY_POD="$(kctl get pod -n apps -l "gateway.networking.k8s.io/gateway-name=demo05b-canary-gw" -o jsonpath='{.items[0].metadata.name}')"
demo_info "prod-gateway pod:   ${PROD_POD}"
demo_info "canary-gateway pod: ${CANARY_POD}"

PROD_ROUTES="$("${ISTIOCTL}" --context "${CONTEXT}" pc routes "${PROD_POD}.apps" 2>/dev/null || true)"
CANARY_ROUTES="$("${ISTIOCTL}" --context "${CONTEXT}" pc routes "${CANARY_POD}.apps" 2>/dev/null || true)"

demo_info "prod-gateway pod routes (rows with 'demo05b'):"
echo "${PROD_ROUTES}" | grep -i "demo05b" | sed 's/^/        /' || echo "        (none)"
demo_info "canary-gateway pod routes (rows with 'demo05b'):"
echo "${CANARY_ROUTES}" | grep -i "demo05b" | sed 's/^/        /' || echo "        (none)"

# ---------------------------------------------------------------------------
# Step 5: assert canary has the route AND prod does not
# ---------------------------------------------------------------------------
if echo "${CANARY_ROUTES}" | grep -qi "demo05b-canary.example.com"; then
    demo_assert_pass "HTTPRoute present on canary-Gateway-provisioned pod"
else
    demo_assert_fail "HTTPRoute MISSING from canary-Gateway-provisioned pod"
fi

if echo "${PROD_ROUTES}" | grep -qi "demo05b-canary.example.com"; then
    demo_assert_fail "HTTPRoute LEAKED to prod-Gateway-provisioned pod (parentRefs scoping broken)"
else
    demo_assert_pass "HTTPRoute absent from prod-Gateway-provisioned pod (parentRefs scoping confirmed)"
fi

demo_end

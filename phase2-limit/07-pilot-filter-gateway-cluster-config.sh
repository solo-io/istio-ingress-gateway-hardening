#!/usr/bin/env bash
# ============================================================================
# Demo #07 — PILOT_FILTER_GATEWAY_CLUSTER_CONFIG
# ============================================================================
#
# HYPOTHESIS
#   With `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG=true` set on istiod, gateway
#   proxies receive ONLY the clusters referenced by VirtualServices attached
#   to that gateway, rather than every cluster in the mesh. Smaller xDS
#   payload means smaller failure surface during a config push.
#
# SETUP
#   - Apply a Gateway demo07-canary-gw and a VirtualService bound to it,
#     routing to one specific Service (httpbin).
#   - Capture pre-toggle cluster count on a canary gateway pod.
#   - Toggle the env var on the istiod Deployment, wait for rollout.
#   - Capture post-toggle cluster count.
#
# PASS CRITERION
#   Cluster count reduction ≥ 30% (per PLAN.md DoD).
#
# IMPORTANT
#   This demo modifies istiod's env vars. Cleanup reverts the change so
#   subsequent demos start from a known state. If run inside run-all.sh,
#   the env var is already on (batched at orchestration step 3) and this
#   demo just measures the delta against the pre-toggle baseline captured
#   earlier.
#
# PRODUCT-IMPROVEMENT NOTE
#   Per istio#54443, this flag is mesh-wide only — no per-Gateway tunability.
#   A Solo-specific per-Gateway annotation would let teams adopt this
#   filter incrementally per gateway. Captured in PLAN.md FR signals.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "07" "pilot-filter-gateway-cluster-config" \
  "PILOT_FILTER_GATEWAY_CLUSTER_CONFIG shrinks gateway xDS cluster set to referenced services only"

TMPDIR_DEMO="$(mktemp -d)"
RESTORE_ENV_VAR=true  # whether cleanup should revert the env var

cleanup_demo() {
    rm -rf "${TMPDIR_DEMO}"
    kctl delete virtualservice demo07-vs -n apps --ignore-not-found 2>/dev/null
    kctl delete gateway demo07-canary-gw -n istio-system --ignore-not-found 2>/dev/null
    if [[ "${RESTORE_ENV_VAR}" == "true" ]]; then
        echo "  • Reverting istiod env var PILOT_FILTER_GATEWAY_CLUSTER_CONFIG..."
        kctl set env deployment/istiod -n istio-system PILOT_FILTER_GATEWAY_CLUSTER_CONFIG- 2>/dev/null
        kctl rollout status deployment/istiod -n istio-system --timeout=120s 2>/dev/null
    fi
}
trap cleanup_demo EXIT

CANARY_POD_LABELS="app=${GATEWAY_APP_LABEL},${TRACK_LABEL_KEY}=${TRACK_CANARY}"

# ---------------------------------------------------------------------------
# Step 1: apply a Gateway and VirtualService routing to ONE service
# ---------------------------------------------------------------------------
demo_step "Applying demo07-canary-gw + VS pointing at httpbin (one referenced cluster)"
cat > "${TMPDIR_DEMO}/manifests.yaml" <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: demo07-canary-gw
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
    hosts: ["demo07.example.com"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: demo07-vs
  namespace: apps
spec:
  hosts: ["demo07.example.com"]
  gateways: ["istio-system/demo07-canary-gw"]
  http:
  - route:
    - destination:
        host: httpbin.apps.svc.cluster.local
        port:
          number: 8000
EOF
kctl apply -f "${TMPDIR_DEMO}/manifests.yaml" >/dev/null
sleep 3

# ---------------------------------------------------------------------------
# Step 2: capture pre-toggle baseline cluster count
# ---------------------------------------------------------------------------
demo_step "Capturing PRE-toggle cluster count on canary gateway pod"
CANARY_POD="$(kctl get pod -n istio-system -l "${CANARY_POD_LABELS}" -o jsonpath='{.items[0].metadata.name}')"
PRE_COUNT="$("${ISTIOCTL}" --context "${CONTEXT}" pc clusters "${CANARY_POD}.istio-system" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
demo_info "Pre-toggle cluster count: ${PRE_COUNT}  (pod: ${CANARY_POD})"

if [[ "${PRE_COUNT}" -lt 10 ]]; then
    demo_assert_fail "Pre-toggle cluster count is suspiciously low (${PRE_COUNT}); expected mesh-wide cluster set"
    demo_end
    exit $?
fi

# ---------------------------------------------------------------------------
# Step 3: toggle PILOT_FILTER_GATEWAY_CLUSTER_CONFIG=true on istiod
# ---------------------------------------------------------------------------
demo_step "Enabling PILOT_FILTER_GATEWAY_CLUSTER_CONFIG=true on istiod"
kctl set env deployment/istiod -n istio-system PILOT_FILTER_GATEWAY_CLUSTER_CONFIG=true >/dev/null
kctl rollout status deployment/istiod -n istio-system --timeout=120s >/dev/null
demo_info "istiod rolled out with new env var"

# Gateway pods need to reconnect to istiod and receive filtered xDS
sleep 8

# ---------------------------------------------------------------------------
# Step 4: capture post-toggle cluster count (re-resolve pod in case it
# was recreated for any reason)
# ---------------------------------------------------------------------------
demo_step "Capturing POST-toggle cluster count"
CANARY_POD="$(kctl get pod -n istio-system -l "${CANARY_POD_LABELS}" -o jsonpath='{.items[0].metadata.name}')"
POST_COUNT="$("${ISTIOCTL}" --context "${CONTEXT}" pc clusters "${CANARY_POD}.istio-system" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
demo_info "Post-toggle cluster count: ${POST_COUNT}  (pod: ${CANARY_POD})"

# ---------------------------------------------------------------------------
# Step 5: compute delta and assert ≥30% reduction
# ---------------------------------------------------------------------------
DELTA=$((PRE_COUNT - POST_COUNT))
PCT_REDUCTION=$(( (DELTA * 100) / PRE_COUNT ))
demo_info "Delta: ${DELTA} clusters removed (${PCT_REDUCTION}% reduction)"

if [[ "${PCT_REDUCTION}" -ge 30 ]]; then
    demo_assert_pass "Cluster count reduced by ${PCT_REDUCTION}% (≥30% threshold met)"
else
    demo_assert_fail "Cluster count reduction ${PCT_REDUCTION}% is below 30% threshold (PRE=${PRE_COUNT}, POST=${POST_COUNT})"
fi

# Also surface a few of the dummy services that should have been filtered out
demo_info "Verifying dummy-services are no longer in the gateway's cluster set..."
DUMMY_HITS="$("${ISTIOCTL}" --context "${CONTEXT}" pc clusters "${CANARY_POD}.istio-system" 2>/dev/null | grep -c "dummy-svc" || true)"
if [[ "${DUMMY_HITS}" -eq 0 ]]; then
    demo_assert_pass "Dummy services (5 in dummy-services ns) filtered out as expected"
else
    demo_assert_fail "Found ${DUMMY_HITS} dummy-svc clusters still present; filter not fully effective"
fi
demo_end

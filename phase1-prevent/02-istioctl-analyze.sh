#!/usr/bin/env bash
# ============================================================================
# Demo #02 — `istioctl analyze` catches cross-resource issues
# ============================================================================
#
# HYPOTHESIS
#   `istioctl analyze` catches the dangling-reference case that the
#   per-object validating webhook (Demo #01) cannot. Running `analyze`
#   as a pre-apply gate in CI closes the gap the webhook leaves.
#
# SETUP
#   Render a candidate VirtualService bound to canary-gateway whose
#   destination.host points at a Service that does not exist.
#
# ACTION
#   Run `istioctl analyze` against the rendered file (NOT the cluster).
#   This is the gate shape a CI pipeline would use: analyze rendered
#   manifests before apply.
#
# VERIFICATION
#   - `istioctl analyze` exits non-zero (signaling CI to block the apply)
#   - Output names the dangling reference (`does not exist`, IST code, etc.)
#
# PRODUCT-IMPROVEMENT NOTE
#   The fact that this requires a separate `analyze` step rather than being
#   built into the admission chain is the underlying gap: a Solo
#   admission-webhook variant that runs analyze server-side would close it.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "02" "istioctl-analyze" \
  "istioctl analyze catches the cross-resource case the webhook misses"

# ---------------------------------------------------------------------------
# Step 1: render a candidate VS with a dangling destination.host
# ---------------------------------------------------------------------------
demo_step "Rendering a candidate VirtualService with a dangling destination.host"
# macOS-portable: mktemp -t puts the random suffix AFTER the extension,
# which makes istioctl analyze skip the file. Use a temp dir instead.
TMPDIR_DEMO02="$(mktemp -d)"
DANGLING_YAML="${TMPDIR_DEMO02}/dangling.yaml"
trap 'rm -rf "${TMPDIR_DEMO02}"' EXIT
# Include the Gateway in the same file so the only dangling reference is
# the destination.host — otherwise istioctl analyze flags the Gateway ref
# too, and the destination-specific signal gets buried in unrelated noise.
cat > "${DANGLING_YAML}" <<'EOF'
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: demo02-canary-gw
  namespace: istio-system
spec:
  selector: {app: ingress-gw, track: canary}
  servers:
  - port: {number: 80, name: http, protocol: HTTP}
    hosts: ["dangling.example.com"]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: demo02-dangling-candidate
  namespace: apps
spec:
  hosts: ["dangling.example.com"]
  gateways: ["istio-system/demo02-canary-gw"]
  http:
  - route:
    - destination:
        host: this-service-truly-does-not-exist
EOF
demo_info "Candidate manifest written to ${DANGLING_YAML}"

# ---------------------------------------------------------------------------
# Step 2: run istioctl analyze against the FILE (pre-apply CI gate shape)
# ---------------------------------------------------------------------------
demo_step "Running 'istioctl analyze' against the rendered file"
ANALYZE_OUTPUT="$("${ISTIOCTL}" --context "${CONTEXT}" analyze -n apps "${DANGLING_YAML}" 2>&1)"
ANALYZE_STATUS=$?
demo_info "istioctl analyze exit: ${ANALYZE_STATUS}"
demo_info "istioctl analyze output:"
echo "${ANALYZE_OUTPUT}" | sed 's/^/        /'

# ---------------------------------------------------------------------------
# Step 3: assert PASS criteria
# ---------------------------------------------------------------------------
# (a) Non-zero exit (so CI can fail the pipeline)
if [[ "${ANALYZE_STATUS}" -ne 0 ]]; then
    demo_assert_pass "istioctl analyze exited non-zero (CI would block the apply)"
else
    demo_assert_fail "istioctl analyze exited zero; CI gate would not catch this"
fi

# (b) Output names the dangling DESTINATION specifically. We require BOTH the
#     IST0101 code AND the literal destination hostname, so unrelated IST0101s
#     (e.g., from cluster-state warnings) can't accidentally satisfy the assertion.
if echo "${ANALYZE_OUTPUT}" | grep -qi "IST0101" \
   && echo "${ANALYZE_OUTPUT}" | grep -qi "this-service-truly-does-not-exist"; then
    demo_assert_pass "Output specifically identifies the dangling destination host (IST0101 + literal hostname)"
else
    demo_assert_fail "Output did not specifically identify the dangling destination host"
fi

# ---------------------------------------------------------------------------
# Step 4 (educational): show that the webhook would still ACCEPT this file
#   — re-asserts the gap from Demo #01 in this demo's own context
# ---------------------------------------------------------------------------
demo_step "Cross-check: webhook would accept this file (gap re-asserted)"
WEBHOOK_OUTPUT="$(kctl apply -f "${DANGLING_YAML}" --dry-run=server 2>&1)"
WEBHOOK_STATUS=$?
demo_info "kubectl apply --dry-run=server exit: ${WEBHOOK_STATUS}"
if [[ "${WEBHOOK_STATUS}" -eq 0 ]]; then
    demo_assert_pass "Webhook (server-side dry-run) accepts the dangling-ref VS, confirming the analyze gap"
else
    demo_assert_fail "Webhook unexpectedly rejected the dangling-ref VS during dry-run"
fi

# Cleanup: the dry-run did not persist, but ensure any leakage is cleared
kctl delete virtualservice demo02-dangling-candidate -n apps --ignore-not-found 2>/dev/null

demo_end

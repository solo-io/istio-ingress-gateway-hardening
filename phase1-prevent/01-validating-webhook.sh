#!/usr/bin/env bash
# ============================================================================
# Demo #01 — Validating admission webhook (server-side, per-object)
# ============================================================================
#
# HYPOTHESIS
#   Istio's validating admission webhook rejects schema-violating
#   networking.istio.io objects at apply time, BUT does NOT catch
#   cross-resource issues (per-object only, confirmed by upstream maintainers
#   in istio/istio#55390). Understanding both halves matters for hardening:
#   the webhook alone is not a sufficient gate.
#
# SETUP
#   Two candidate VirtualService resources:
#     - bad-schema.yaml: negative HTTP route weight (-1) — schema violation
#     - dangling-ref.yaml: destination.host points at a Service that doesn't exist
#
# ACTION
#   Try to apply each.
#
# VERIFICATION
#   - bad-schema.yaml MUST be rejected by the webhook
#   - dangling-ref.yaml MUST be accepted (demonstrates per-object-only limit)
#
# PASS criterion
#   Both expected outcomes observed. The demo's value isn't just "webhook
#   works" — it's "webhook works for X but NOT for Y, here's the gap."
#
# PRODUCT-IMPROVEMENT NOTE
#   The dangling-reference case is exactly what istioctl analyze (Demo #02)
#   catches; running both gates is the documented best practice. Open
#   question for product: should Solo ship a server-side analyze-on-apply
#   variant that closes this gap in the admission chain?
# ============================================================================
set -uo pipefail   # NOTE: no `-e` because we EXPECT certain commands to fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "01" "validating-webhook" \
  "Istio admission webhook rejects schema errors but NOT cross-resource references"

# ---------------------------------------------------------------------------
# Step 1: apply a schema-invalid VirtualService (bad port protocol enum)
# ---------------------------------------------------------------------------
demo_step "Applying a VirtualService with a schema-invalid http weight (-1)"
# macOS `mktemp -t TEMPLATE.yaml` puts the random suffix AFTER the .yaml
# extension — see iteration finding in the README. Use mktemp -d + a known
# filename instead so the .yaml extension stays at the end of the path.
TMPDIR_DEMO01="$(mktemp -d)"
BAD_SCHEMA_YAML="${TMPDIR_DEMO01}/bad-schema.yaml"
DANGLING_REF_YAML="${TMPDIR_DEMO01}/dangling-ref.yaml"
trap 'rm -rf "${TMPDIR_DEMO01}"' EXIT
cat > "${BAD_SCHEMA_YAML}" <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: demo01-bad-schema
  namespace: apps
spec:
  hosts: ["bad.example.com"]
  http:
  - route:
    - destination:
        host: httpbin
      weight: -1   # negative weight is a schema violation
EOF
APPLY_OUTPUT="$(kctl apply -f "${BAD_SCHEMA_YAML}" 2>&1)"
APPLY_STATUS=$?
demo_info "kubectl apply exit: ${APPLY_STATUS}"
demo_info "kubectl apply output (first 200 chars): ${APPLY_OUTPUT:0:200}"

# We need the apply to FAIL with a webhook rejection.
if [[ "${APPLY_STATUS}" -ne 0 ]] && echo "${APPLY_OUTPUT}" | grep -qiE "admission webhook|validation"; then
    demo_assert_pass "Webhook rejected the schema-invalid VirtualService"
else
    demo_assert_fail "Expected webhook rejection; got exit=${APPLY_STATUS}, output did not match"
    # If it persisted, clean it up
    kctl delete -f "${BAD_SCHEMA_YAML}" --ignore-not-found 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Step 2: apply a VirtualService with a dangling Service reference
#          (webhook should ACCEPT this — per-object validation only)
# ---------------------------------------------------------------------------
demo_step "Applying a VirtualService pointing at a non-existent destination Service"
cat > "${DANGLING_REF_YAML}" <<'EOF'
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: demo01-dangling-ref
  namespace: apps
spec:
  hosts: ["dangling.example.com"]
  http:
  - route:
    - destination:
        host: this-service-does-not-exist
EOF
APPLY_OUTPUT="$(kctl apply -f "${DANGLING_REF_YAML}" 2>&1)"
APPLY_STATUS=$?
demo_info "kubectl apply exit: ${APPLY_STATUS}"
demo_info "kubectl apply output: ${APPLY_OUTPUT}"

if [[ "${APPLY_STATUS}" -eq 0 ]] && kctl get virtualservice demo01-dangling-ref -n apps &>/dev/null; then
    demo_assert_pass "Webhook accepted dangling-reference VS (confirms per-object-only validation, per istio#55390)"
else
    demo_assert_fail "Expected webhook to accept dangling-reference VS; got exit=${APPLY_STATUS}"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
demo_step "Cleanup"
kctl delete virtualservice demo01-dangling-ref -n apps --ignore-not-found 2>/dev/null
kctl delete virtualservice demo01-bad-schema -n apps --ignore-not-found 2>/dev/null

demo_end

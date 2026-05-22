#!/usr/bin/env bash
# ============================================================================
# Demo #03 — ValidatingAdmissionPolicy (CEL) enforces team-specific invariants
# ============================================================================
#
# HYPOTHESIS
#   Kubernetes 1.30+ ValidatingAdmissionPolicy lets the platform team encode
#   gateway-hardening invariants as CEL rules enforced by the kube-apiserver,
#   alongside the Istio webhook. A policy that forbids `hosts: ['*']` on
#   Gateway resources is rejected by the apiserver before istiod sees it.
#
# SETUP
#   Apply two ValidatingAdmissionPolicies + Bindings:
#     - One targeting Istio Gateway (networking.istio.io)
#     - One targeting Gateway API Gateway (gateway.networking.k8s.io)
#
# ACTION
#   For each API surface, attempt to apply a wildcard-host Gateway.
#
# VERIFICATION
#   - Istio Gateway with hosts: ['*'] is REJECTED with a message citing the
#     policy name and the rule
#   - Gateway API Gateway with hostname: '*' is REJECTED similarly
#   - A well-formed Gateway (specific host) is ACCEPTED (control case)
#
# PRODUCT-IMPROVEMENT NOTE
#   Solo doesn't ship a blessed VAP library for common gateway-hardening
#   invariants. A `gateway-hardening-vap-library` chart or docs page with
#   vetted CEL rules would let customers adopt these gates without authoring
#   them from scratch.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/cluster-vars.sh"
source "${SCRIPT_DIR}/../lib/pass-fail.sh"

ensure_cluster_up || exit 1

demo_start "03" "validating-admission-policy" \
  "CEL ValidatingAdmissionPolicy rejects wildcard-host Gateways on both APIs"

# ---------------------------------------------------------------------------
# Pre-flight: K8s 1.30+ required for VAP
# ---------------------------------------------------------------------------
K8S_MINOR="$(kctl version -o json 2>/dev/null | jq -r '.serverVersion.minor' | tr -d '+')"
if [[ -z "${K8S_MINOR}" ]] || [[ "${K8S_MINOR}" -lt 30 ]]; then
    demo_assert_fail "K8s 1.30+ required for ValidatingAdmissionPolicy; cluster minor='${K8S_MINOR}'"
    demo_end
    exit $?
fi
demo_info "K8s 1.30+ confirmed (minor=${K8S_MINOR})"

# ---------------------------------------------------------------------------
# Step 1: install both policies
# ---------------------------------------------------------------------------
demo_step "Installing ValidatingAdmissionPolicies for both API surfaces"
TMPDIR_DEMO03="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_DEMO03}"; kctl delete validatingadmissionpolicybinding demo03-istio-no-wildcard demo03-gwapi-no-wildcard --ignore-not-found 2>/dev/null; kctl delete validatingadmissionpolicy demo03-istio-no-wildcard demo03-gwapi-no-wildcard --ignore-not-found 2>/dev/null' EXIT

cat > "${TMPDIR_DEMO03}/policies.yaml" <<'EOF'
---
# Policy A: Istio Gateway (networking.istio.io) — no wildcard hosts in servers
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: demo03-istio-no-wildcard
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups: ["networking.istio.io"]
      apiVersions: ["v1", "v1beta1", "v1alpha3"]
      operations: ["CREATE", "UPDATE"]
      resources: ["gateways"]
  validations:
  - expression: "!has(object.spec.servers) || !object.spec.servers.exists(s, '*' in s.hosts)"
    message: "Istio Gateway must not list '*' in any server's hosts (org policy demo03-istio-no-wildcard)"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: demo03-istio-no-wildcard
spec:
  policyName: demo03-istio-no-wildcard
  validationActions: ["Deny"]
---
# Policy B: Gateway API Gateway (gateway.networking.k8s.io) — every listener
# MUST explicitly set `hostname`. A missing hostname means "match any host"
# (the Gateway API equivalent of Istio `hosts: ['*']`). Note: the CRD's
# built-in regex already blocks `hostname: "*"` literally, so the realistic
# org rule for hardening is "listeners must explicitly scope by hostname".
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: demo03-gwapi-no-wildcard
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups: ["gateway.networking.k8s.io"]
      apiVersions: ["v1", "v1beta1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["gateways"]
  validations:
  - expression: "!has(object.spec.listeners) || object.spec.listeners.all(l, has(l.hostname) && l.hostname != '')"
    message: "Gateway API Gateway listeners must explicitly set a non-empty hostname (org policy demo03-gwapi-no-wildcard)"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: demo03-gwapi-no-wildcard
spec:
  policyName: demo03-gwapi-no-wildcard
  validationActions: ["Deny"]
EOF
kctl apply -f "${TMPDIR_DEMO03}/policies.yaml" >/dev/null

# VAP bindings take a moment to propagate; small wait
sleep 2
demo_info "Both policies installed: demo03-istio-no-wildcard, demo03-gwapi-no-wildcard"

# ---------------------------------------------------------------------------
# Step 2: try to apply a violating Istio Gateway (hosts: ['*'])
# ---------------------------------------------------------------------------
demo_step "Applying a violating Istio Gateway with hosts: ['*']"
cat > "${TMPDIR_DEMO03}/bad-istio-gw.yaml" <<'EOF'
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: demo03-bad-istio-gw
  namespace: apps
spec:
  selector:
    app: ingress-gw
    track: canary
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts: ["*"]    # VIOLATES policy
EOF
OUT="$(kctl apply -f "${TMPDIR_DEMO03}/bad-istio-gw.yaml" 2>&1)"
STATUS=$?
demo_info "exit: ${STATUS}  output: ${OUT:0:300}"
if [[ "${STATUS}" -ne 0 ]] && echo "${OUT}" | grep -q "demo03-istio-no-wildcard"; then
    demo_assert_pass "Istio Gateway rejected by VAP (policy name in error)"
else
    demo_assert_fail "Expected VAP rejection of Istio Gateway; got exit=${STATUS}"
    kctl delete gateway demo03-bad-istio-gw -n apps --ignore-not-found 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Step 3: try to apply a violating Gateway API Gateway (hostname: '*')
# ---------------------------------------------------------------------------
demo_step "Applying a violating Gateway API Gateway with no listener hostname (matches any host)"
cat > "${TMPDIR_DEMO03}/bad-gwapi-gw.yaml" <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: demo03-bad-gwapi-gw
  namespace: apps
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    # hostname intentionally omitted → matches any host → VIOLATES policy
EOF
OUT="$(kctl apply -f "${TMPDIR_DEMO03}/bad-gwapi-gw.yaml" 2>&1)"
STATUS=$?
demo_info "exit: ${STATUS}  output: ${OUT:0:300}"
if [[ "${STATUS}" -ne 0 ]] && echo "${OUT}" | grep -q "demo03-gwapi-no-wildcard"; then
    demo_assert_pass "Gateway API Gateway rejected by VAP (policy name in error)"
else
    demo_assert_fail "Expected VAP rejection of Gateway API Gateway; got exit=${STATUS}"
    kctl delete gateway.gateway.networking.k8s.io demo03-bad-gwapi-gw -n apps --ignore-not-found 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Step 4: control case — well-formed Istio Gateway with a specific host is OK
# ---------------------------------------------------------------------------
demo_step "Control case: well-formed Istio Gateway with specific host should be ACCEPTED"
cat > "${TMPDIR_DEMO03}/good-istio-gw.yaml" <<'EOF'
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: demo03-good-istio-gw
  namespace: apps
spec:
  selector:
    app: ingress-gw
    track: canary
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts: ["foo.example.com"]   # specific host, allowed
EOF
OUT="$(kctl apply -f "${TMPDIR_DEMO03}/good-istio-gw.yaml" 2>&1)"
STATUS=$?
demo_info "exit: ${STATUS}  output: ${OUT:0:200}"
if [[ "${STATUS}" -eq 0 ]]; then
    demo_assert_pass "Well-formed Gateway accepted (policy is targeted, not over-broad)"
else
    demo_assert_fail "Well-formed Gateway should have been accepted; got exit=${STATUS}"
fi
kctl delete gateway demo03-good-istio-gw -n apps --ignore-not-found 2>/dev/null

demo_end

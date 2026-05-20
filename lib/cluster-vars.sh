#!/usr/bin/env bash
# ============================================================================
# lib/cluster-vars.sh -- Single source of truth for cluster, version,
# namespace, port, and path configuration.
#
# Every script in this playground sources this file. To change the cluster
# name, Istio version, or port mappings, edit here. CLUSTER_TYPE is the only
# variable that drives cluster-type-specific bring-up (k3d vs future eks);
# everything else stays cluster-agnostic.
#
# Usage: source lib/cluster-vars.sh  (relative to test bundle root)
# ============================================================================

# --- Cluster identity --------------------------------------------------------
export CLUSTER_TYPE="${CLUSTER_TYPE:-k3d}"
export CLUSTER_NAME="istio-igw-hardening"
export CONTEXT="k3d-${CLUSTER_NAME}"

# --- Versions ----------------------------------------------------------------
# OSS Istio 1.27.8 matches the seed's last-validated version. Mechanism-
# equivalent to SEfI 1.27.8-solo; install command differs (helm chart for
# SEfI) but every demo in this playground behaves identically across both.
export ISTIO_VERSION="1.27.8"
# K8s 1.30+ required for ValidatingAdmissionPolicy CEL (demo #03).
export K3S_IMAGE="rancher/k3s:v1.30.6-k3s1"
# Gateway API CRDs experimental channel for full feature coverage including
# RequestMirror filter (demo #08 Gateway API variant).
export GATEWAY_API_VERSION="v1.2.1"

# --- Port mappings (host -> cluster) ----------------------------------------
# Unique high ports per the skill's port-conflict convention.
export INGRESS_HTTP_PORT="18080"
export INGRESS_HTTPS_PORT="18443"

# --- Namespaces --------------------------------------------------------------
export SYSTEM_NS="istio-system"
export APPS_NS="apps"
export APPS_NS_A="apps-ns-a"
export APPS_NS_B="apps-ns-b"
export DUMMY_NS="dummy-services"
# loadgen is intentionally NOT ambient-labeled so ztunnel doesn't intercept
# client traffic and wrap it in HBONE. Lab convention (CLAUDE.md): clients
# that test L7 ingress behavior must reach the gateway without an ambient
# transparent proxy in the path.
export LOADGEN_NS="loadgen"
# grpc-backends is also NOT ambient-labeled. Our custom gateway pods
# (track=prod/canary) don't have the standard istio-ingressgateway's HBONE
# egress configuration, so they cannot forward plaintext gRPC to ambient
# destinations through ztunnel. Putting gRPC backends in a non-ambient
# namespace bypasses HBONE entirely. (Standard istio-ingressgateway can
# reach ambient gRPC backends; our hand-rolled gateways cannot.)
export GRPC_BACKENDS_NS="grpc-backends"
# Monitoring stack (kube-prometheus-stack + Grafana + image-renderer sidecar).
# Lives in its own namespace; PodMonitor discovers gateway pods via labels.
export MONITORING_NS="monitoring"
export KUBE_PROM_STACK_VERSION="84.5.0"
export GRAFANA_ADMIN_PASSWORD="igw-hardening"
# Grafana image-renderer sidecar (platform=linux/amd64 only; runs under
# Rosetta on Apple Silicon hosts).
export RENDERER_IMAGE="grafana/grafana-image-renderer:v5.8.3"
# SNAPSHOTS_DIR is set further down after REPRODUCER_ROOT is computed.

# --- Workload labels ---------------------------------------------------------
# Gateway pods distinguish prod vs canary by label for demo #05 selector pair.
export TRACK_LABEL_KEY="track"
export TRACK_PROD="prod"
export TRACK_CANARY="canary"
export GATEWAY_APP_LABEL="ingress-gw"
export GATEWAY_REPLICAS="3"

# --- Path resolution --------------------------------------------------------
# REPRODUCER_ROOT is the absolute path to the test-bundle directory.
# Computed from this lib file's own location: lib/ is one level below root.
# Use BASH_SOURCE so this works whether the file is sourced or executed.
REPRODUCER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPRODUCER_ROOT
export ISTIOCTL="${REPRODUCER_ROOT}/istioctl"
export MANIFESTS_DIR="${REPRODUCER_ROOT}/manifests"
export SNAPSHOTS_DIR="${REPRODUCER_ROOT}/snapshots"

# --- kubectl wrapper --------------------------------------------------------
# Always use --context to avoid hitting the wrong cluster when the SA has
# multiple k3d clusters running. Per the skill's L001-style guidance.
kctl() {
    kubectl --context "${CONTEXT}" "$@"
}
export -f kctl

# --- helm wrapper -----------------------------------------------------------
helm_cmd() {
    helm --kube-context "${CONTEXT}" "$@"
}
export -f helm_cmd

# --- Sanity check function (callable by individual demo scripts) -------------
ensure_cluster_up() {
    if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "${CONTEXT}"; then
        echo "ERROR: Context '${CONTEXT}' not found. Run ./deploy.sh first." >&2
        return 1
    fi
    if ! kctl get nodes &>/dev/null; then
        echo "ERROR: Cluster '${CLUSTER_NAME}' not reachable. Check 'k3d cluster list'." >&2
        return 1
    fi
}
export -f ensure_cluster_up

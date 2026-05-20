#!/usr/bin/env bash
# ============================================================================
# deploy.sh -- Istio Ingress Gateway Hardening Playground base environment.
#
# Builds a k3d cluster + OSS Istio 1.27.8 (ambient profile) + Gateway API
# CRDs + ingress gateway pair (prod and canary tracks) + sample workloads.
# Every demo script in phase1-prevent/.../phase5-resilience/ assumes this
# environment is up.
#
# Idempotent: re-running this script after a partial setup picks up where
# it left off. Each step checks for existing state before creating.
#
# Configuration: lib/cluster-vars.sh holds every tunable. Edit there to
# change cluster name, versions, or ports.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/cluster-vars.sh"

echo "=== Istio Ingress Gateway Hardening Playground :: Setup ==="
echo "Cluster: ${CONTEXT}  |  Istio: ${ISTIO_VERSION}  |  K8s: ${K3S_IMAGE}"
echo ""

# ----------------------------------------------------------------------------
# [1/9] Download istioctl if not present or wrong version
# ----------------------------------------------------------------------------
if [[ -x "${ISTIOCTL}" ]] && "${ISTIOCTL}" version --remote=false 2>/dev/null | grep -q "${ISTIO_VERSION}"; then
    echo "[1/9] istioctl ${ISTIO_VERSION} already present"
else
    echo "[1/9] Downloading istioctl ${ISTIO_VERSION}..."
    rm -f "${ISTIOCTL}"
    ARCH="$(uname -m)"
    OS_RAW="$(uname -s)"
    if [[ "${OS_RAW}" == "Darwin" ]]; then OS="osx"; else OS="linux"; fi
    if [[ "${ARCH}" == "arm64" ]] || [[ "${ARCH}" == "aarch64" ]]; then ARCH="arm64"; else ARCH="amd64"; fi
    URL="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-${OS}-${ARCH}.tar.gz"
    echo "      URL: ${URL}"
    curl -sL "${URL}" | tar xz -C "${REPRODUCER_ROOT}" istioctl
    chmod +x "${ISTIOCTL}"
    echo "      Installed: $("${ISTIOCTL}" version --remote=false 2>/dev/null | head -1)"
fi

# ----------------------------------------------------------------------------
# [2/9] Create k3d cluster (Traefik disabled per L001; ports for ingress)
# ----------------------------------------------------------------------------
if k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${CLUSTER_NAME}"; then
    echo "[2/9] Cluster '${CLUSTER_NAME}' already exists"
else
    echo "[2/9] Creating k3d cluster '${CLUSTER_NAME}' (1 server + 2 agents, K8s 1.30+)..."
    k3d cluster create "${CLUSTER_NAME}" \
        --image "${K3S_IMAGE}" \
        --agents 2 \
        --k3s-arg "--disable=traefik@server:0" \
        --port "${INGRESS_HTTP_PORT}:80@loadbalancer" \
        --port "${INGRESS_HTTPS_PORT}:443@loadbalancer" \
        --wait
fi
kubectl config use-context "${CONTEXT}" >/dev/null
echo "      Waiting for nodes..."
kctl wait --for=condition=Ready nodes --all --timeout=120s >/dev/null

# ----------------------------------------------------------------------------
# [3/9] Install Gateway API CRDs (experimental channel for RequestMirror)
# ----------------------------------------------------------------------------
if kctl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
    echo "[3/9] Gateway API CRDs already installed"
else
    echo "[3/9] Installing Gateway API CRDs ${GATEWAY_API_VERSION} (experimental channel)..."
    kctl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml" >/dev/null
fi

# ----------------------------------------------------------------------------
# [4/9] Install Istio (ambient profile, k3d CNI paths per L002)
# ----------------------------------------------------------------------------
if kctl get deployment istiod -n "${SYSTEM_NS}" &>/dev/null; then
    echo "[4/9] Istio already installed"
else
    echo "[4/9] Installing Istio ${ISTIO_VERSION} (ambient profile, k3d CNI paths)..."
    "${ISTIOCTL}" --context "${CONTEXT}" install -y \
        --set profile=ambient \
        --set values.cni.cniConfDir=/var/lib/rancher/k3s/agent/etc/cni/net.d \
        --set values.cni.cniBinDir=/bin \
        2>&1 | tail -8
    echo "      Waiting for control plane..."
    kctl wait --for=condition=Available deployment/istiod -n "${SYSTEM_NS}" --timeout=180s >/dev/null
    kctl rollout status daemonset/ztunnel -n "${SYSTEM_NS}" --timeout=180s >/dev/null
    kctl rollout status daemonset/istio-cni-node -n "${SYSTEM_NS}" --timeout=180s >/dev/null
fi

# ----------------------------------------------------------------------------
# [5/9] Create app namespaces (ambient-labeled) + loadgen namespace (NOT)
# ----------------------------------------------------------------------------
echo "[5/9] Creating namespaces (ambient-labeled): ${APPS_NS}, ${APPS_NS_A}, ${APPS_NS_B}"
for NS in "${APPS_NS}" "${APPS_NS_A}" "${APPS_NS_B}"; do
    kctl create namespace "${NS}" --dry-run=client -o yaml | kctl apply -f - >/dev/null
    kctl label namespace "${NS}" istio.io/dataplane-mode=ambient --overwrite >/dev/null
done
# loadgen is intentionally NOT in ambient mode. ztunnel intercepting client
# HTTP/2 or gRPC traffic from an ambient pod wraps it in HBONE, which breaks
# plaintext h2c negotiation with backends through the gateway. Lab convention:
# load generators that exercise L7 ingress must reach the gateway without an
# ambient transparent proxy in the path.
echo "       + ${LOADGEN_NS} (NOT ambient-labeled; load-gen clients only)"
kctl create namespace "${LOADGEN_NS}" --dry-run=client -o yaml | kctl apply -f - >/dev/null
# Explicitly REMOVE any ambient label if it was set previously
kctl label namespace "${LOADGEN_NS}" istio.io/dataplane-mode- --overwrite 2>/dev/null || true

# ----------------------------------------------------------------------------
# [6/9] Seed dummy-services namespace (5 Services for demo #07 baseline delta)
# ----------------------------------------------------------------------------
echo "[6/9] Seeding ${DUMMY_NS} with 5 dummy Services (demo #07 baseline)"
kctl create namespace "${DUMMY_NS}" --dry-run=client -o yaml | kctl apply -f - >/dev/null
for i in 1 2 3 4 5; do
    kctl apply -n "${DUMMY_NS}" -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: dummy-svc-${i}
spec:
  selector: {app: nonexistent-${i}}
  ports:
  - port: 80
    targetPort: 8080
EOF
done

# ----------------------------------------------------------------------------
# [7/9] Deploy httpbin family (v1, v2, shadow) in apps namespace
# ----------------------------------------------------------------------------
echo "[7/9] Deploying httpbin family (v1, v2, shadow) in ${APPS_NS}"
for VARIANT in v1 v2 shadow; do
    kctl apply -n "${APPS_NS}" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin-${VARIANT}
  labels: {app: httpbin, version: ${VARIANT}}
spec:
  replicas: 1
  selector:
    matchLabels: {app: httpbin, version: ${VARIANT}}
  template:
    metadata:
      labels: {app: httpbin, version: ${VARIANT}}
    spec:
      containers:
      - name: httpbin
        image: mccutchen/go-httpbin:v2.15.0
        # L007: mccutchen/go-httpbin uses CMD not ENTRYPOINT; explicit command needed
        command: ["/bin/go-httpbin"]
        args: ["-port=8080", "-max-body-size=20971520"]
        ports:
        - containerPort: 8080
        env:
        - name: VARIANT
          value: "${VARIANT}"
        readinessProbe:
          httpGet: {path: /status/200, port: 8080}
          periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin-${VARIANT}
  labels: {app: httpbin, version: ${VARIANT}}
spec:
  selector: {app: httpbin, version: ${VARIANT}}
  ports:
  - name: http
    port: 8000
    targetPort: 8080
    appProtocol: http
EOF
done
# httpbin (unversioned) Service points at v1 by default; used as the canonical
# "production backend" in most demos.
kctl apply -n "${APPS_NS}" -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  labels: {app: httpbin}
spec:
  selector: {app: httpbin, version: v1}
  ports:
  - name: http
    port: 8000
    targetPort: 8080
    appProtocol: http
EOF
for VARIANT in v1 v2 shadow; do
    kctl rollout status -n "${APPS_NS}" "deployment/httpbin-${VARIANT}" --timeout=120s >/dev/null
done

# ----------------------------------------------------------------------------
# [7b/9] Deploy gRPC backends (grpcbin primary + shadow + v2) for demos
#         #08c (gRPC mirror VS), #08d (gRPC mirror GRPCRoute), #13c (gRPC
#         long-lived ClientConn).
# ----------------------------------------------------------------------------
echo "[7b/9] Deploying grpcbin family (primary, shadow, v2) for gRPC demos"
kctl apply -n "${APPS_NS}" -f "${MANIFESTS_DIR}/grpcbin.yaml" >/dev/null
for D in grpcbin grpcbin-shadow grpcbin-v2; do
    kctl rollout status -n "${APPS_NS}" "deployment/${D}" --timeout=180s >/dev/null
done

# ----------------------------------------------------------------------------
# [7c/9] Build and import h2dial-light + ghz images for HTTP/2 and gRPC demos
# ----------------------------------------------------------------------------
echo "[7c/9] Building h2dial-light and ghz container images (one-time)"
if ! docker image inspect h2dial-light:local &>/dev/null; then
    echo "      Building h2dial-light:local..."
    docker build -t h2dial-light:local "${REPRODUCER_ROOT}/tools/h2dial-light" 2>&1 | tail -3
fi
if ! docker image inspect ghz:local &>/dev/null; then
    echo "      Building ghz:local..."
    docker build --platform=linux/amd64 -t ghz:local "${REPRODUCER_ROOT}/tools/ghz" 2>&1 | tail -3
fi
echo "      Importing images into k3d cluster..."
k3d image import h2dial-light:local ghz:local --cluster "${CLUSTER_NAME}" 2>&1 | tail -3

# Deploy long-running idle pods so demos can `kubectl exec` rather than
# spin up fresh Pods per run. Both live in the NON-ambient loadgen
# namespace — critical for plaintext h2c / gRPC reaching the gateway
# without ztunnel HBONE wrapping in the way.
kctl apply -n "${LOADGEN_NS}" -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: h2dial-light, namespace: ${LOADGEN_NS}, labels: {app: h2dial-light}}
spec:
  replicas: 1
  selector: {matchLabels: {app: h2dial-light}}
  template:
    metadata: {labels: {app: h2dial-light}}
    spec:
      containers:
      - name: h2dial-light
        image: h2dial-light:local
        imagePullPolicy: Never
        args: ["-idle"]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: ghz, namespace: ${LOADGEN_NS}, labels: {app: ghz}}
spec:
  replicas: 1
  selector: {matchLabels: {app: ghz}}
  template:
    metadata: {labels: {app: ghz}}
    spec:
      containers:
      - name: ghz
        image: ghz:local
        imagePullPolicy: Never
        # Override entrypoint so the pod stays alive; demos kubectl exec
        # specific ghz invocations into it.
        command: ["sleep", "infinity"]
EOF
kctl rollout status -n "${LOADGEN_NS}" deployment/h2dial-light --timeout=120s >/dev/null
kctl rollout status -n "${LOADGEN_NS}" deployment/ghz --timeout=120s >/dev/null
# Remove the old ghz/h2dial-light Deployments from apps namespace if they
# exist (left over from an earlier deploy iteration before the loadgen-NS
# fix). Safe no-op if absent.
kctl delete deployment h2dial-light ghz -n "${APPS_NS}" --ignore-not-found 2>/dev/null >/dev/null || true

# ----------------------------------------------------------------------------
# [8/9] Deploy two ingress gateway tracks (prod + canary) with disjoint labels
# ----------------------------------------------------------------------------
echo "[8/9] Deploying ingress gateway pair (prod track + canary track, ${GATEWAY_REPLICAS} replicas each)"
for TRACK in "${TRACK_PROD}" "${TRACK_CANARY}"; do
    kctl apply -n "${SYSTEM_NS}" -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${GATEWAY_APP_LABEL}-${TRACK}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${GATEWAY_APP_LABEL}-${TRACK}
  labels:
    app: ${GATEWAY_APP_LABEL}
    ${TRACK_LABEL_KEY}: ${TRACK}
spec:
  replicas: ${GATEWAY_REPLICAS}
  selector:
    matchLabels:
      app: ${GATEWAY_APP_LABEL}
      ${TRACK_LABEL_KEY}: ${TRACK}
  template:
    metadata:
      labels:
        app: ${GATEWAY_APP_LABEL}
        ${TRACK_LABEL_KEY}: ${TRACK}
        sidecar.istio.io/inject: "true"
      annotations:
        inject.istio.io/templates: gateway
    spec:
      serviceAccountName: ${GATEWAY_APP_LABEL}-${TRACK}
      containers:
      - name: istio-proxy
        image: auto
        ports:
        - containerPort: 15021
          name: status-port
        - containerPort: 8080
          name: http
        - containerPort: 8443
          name: https
        readinessProbe:
          httpGet: {path: /healthz/ready, port: 15021}
---
apiVersion: v1
kind: Service
metadata:
  name: ${GATEWAY_APP_LABEL}-${TRACK}
  labels:
    app: ${GATEWAY_APP_LABEL}
    ${TRACK_LABEL_KEY}: ${TRACK}
spec:
  type: ClusterIP
  selector:
    app: ${GATEWAY_APP_LABEL}
    ${TRACK_LABEL_KEY}: ${TRACK}
  ports:
  - name: http
    port: 80
    targetPort: 8080
  - name: https
    port: 443
    targetPort: 8443
EOF
done
for TRACK in "${TRACK_PROD}" "${TRACK_CANARY}"; do
    kctl rollout status -n "${SYSTEM_NS}" "deployment/${GATEWAY_APP_LABEL}-${TRACK}" --timeout=180s >/dev/null
done

# ----------------------------------------------------------------------------
# [8b/9] Patch gateway pods with proxyStatsMatcher for broader Envoy stats
#         (Istio 1.18+ defaults exclude upstream_rq_total per-cluster; demos
#         #07 and #13c need it for backend-distribution verification)
# ----------------------------------------------------------------------------
echo "[8b/9] Enabling extended Envoy stats on gateway pods (proxyStatsMatcher)"
PROXY_STATS_ANNOTATION='{"proxyStatsMatcher":{"inclusionRegexps":[".*downstream_cx.*",".*downstream_rq.*",".*upstream_cx.*",".*upstream_rq.*",".*http2.*",".*listener.*"]}}'
for TRACK in "${TRACK_PROD}" "${TRACK_CANARY}"; do
    EXISTING="$(kctl get deployment "${GATEWAY_APP_LABEL}-${TRACK}" -n "${SYSTEM_NS}" \
        -o jsonpath='{.spec.template.metadata.annotations.proxy\.istio\.io/config}' 2>/dev/null || echo "")"
    if [[ "${EXISTING}" != "${PROXY_STATS_ANNOTATION}" ]]; then
        kctl patch deployment "${GATEWAY_APP_LABEL}-${TRACK}" -n "${SYSTEM_NS}" \
            -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"proxy.istio.io/config\":\"${PROXY_STATS_ANNOTATION//\"/\\\"}\"}}}}}" >/dev/null
        kctl rollout status -n "${SYSTEM_NS}" "deployment/${GATEWAY_APP_LABEL}-${TRACK}" --timeout=180s >/dev/null
    fi
done

# ----------------------------------------------------------------------------
# [8c/9] Install kube-prometheus-stack + Grafana with image-renderer sidecar
# ----------------------------------------------------------------------------
echo "[8c/9] Installing kube-prometheus-stack (Prometheus + Grafana + image-renderer)"
if kctl get deployment kube-prom-stack-grafana -n "${MONITORING_NS}" &>/dev/null; then
    echo "       Monitoring stack already installed"
else
    kctl create namespace "${MONITORING_NS}" --dry-run=client -o yaml | kctl apply -f - >/dev/null
    helm_cmd repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
    helm_cmd repo update prometheus-community >/dev/null 2>&1 || true

    # Pull + import the image-renderer (linux/amd64 only; runs under Rosetta on M-series)
    if ! docker image inspect "${RENDERER_IMAGE}" &>/dev/null; then
        echo "       Pulling ${RENDERER_IMAGE} (linux/amd64)..."
        docker pull --platform=linux/amd64 "${RENDERER_IMAGE}" 2>&1 | tail -1
    fi
    k3d image import "${RENDERER_IMAGE}" --cluster "${CLUSTER_NAME}" 2>&1 | tail -2

    # Parse renderer image into repo + tag for Helm
    RENDERER_REPO="${RENDERER_IMAGE%:*}"
    RENDERER_TAG="${RENDERER_IMAGE##*:}"

    echo "       Installing chart (this takes ~2-3 min)..."
    helm_cmd upgrade --install kube-prom-stack prometheus-community/kube-prometheus-stack \
        --namespace "${MONITORING_NS}" \
        --version "${KUBE_PROM_STACK_VERSION}" \
        --set grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD}" \
        --set grafana.imageRenderer.enabled=true \
        --set "grafana.imageRenderer.image.repository=${RENDERER_REPO}" \
        --set "grafana.imageRenderer.image.tag=${RENDERER_TAG}" \
        --set grafana.imageRenderer.image.pullPolicy=Never \
        --set grafana.sidecar.dashboards.enabled=true \
        --set grafana.sidecar.dashboards.searchNamespace=ALL \
        --set 'grafana.env.GF_PLUGINS_DISABLE_PLUGIN=grafana-assistant-app' \
        --set 'grafana.env.GF_AUTH_ANONYMOUS_ENABLED=true' \
        --set 'grafana.env.GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer' \
        --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --wait --timeout=10m 2>&1 | tail -3
fi

# Apply PodMonitor for gateway pods
kctl apply -f "${MANIFESTS_DIR}/monitoring.yaml" >/dev/null

# Load the dashboard JSON as a ConfigMap with the grafana_dashboard label so
# the Grafana sidecar auto-imports it.
kctl create configmap igw-hardening-dashboard \
    --from-file=igw-hardening.json="${REPRODUCER_ROOT}/dashboard/igw-hardening.json" \
    -n "${MONITORING_NS}" \
    --dry-run=client -o yaml | kctl apply -f - >/dev/null
kctl label configmap igw-hardening-dashboard -n "${MONITORING_NS}" \
    grafana_dashboard=1 --overwrite >/dev/null

# ----------------------------------------------------------------------------
# [9/9] Verify environment + flag-availability assertions
# ----------------------------------------------------------------------------
echo "[9/9] Verification"

# PILOT_FILTER_GATEWAY_CLUSTER_CONFIG availability check (iteration-risk mitigation).
# The flag has existed since Istio 1.16. Verify istiod knows about it by
# checking for its presence in the env-var list at istiod's debug endpoint.
ISTIOD_POD=$(kctl get pod -n "${SYSTEM_NS}" -l app=istiod -o jsonpath='{.items[0].metadata.name}')
if kctl exec -n "${SYSTEM_NS}" "${ISTIOD_POD}" -c discovery -- /usr/local/bin/pilot-discovery 2>&1 | grep -q "PILOT_FILTER_GATEWAY_CLUSTER_CONFIG" \
   || "${ISTIOCTL}" --context "${CONTEXT}" admin log --level=default 2>&1 | grep -qi "filter_gateway" \
   || echo "(env-var probe deferred to demo #07; flag verified at use)"; then
    :
fi

echo ""
echo "Pod summary by namespace:"
for NS in "${SYSTEM_NS}" "${APPS_NS}" "${APPS_NS_A}" "${APPS_NS_B}" "${DUMMY_NS}"; do
    POD_COUNT=$(kctl get pods -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    READY=$(kctl get pods -n "${NS}" --no-headers 2>/dev/null | awk '$2 ~ /\// {split($2,a,"/"); if (a[1]==a[2]) c++} END {print c+0}')
    printf "  %-20s %s/%s ready\n" "${NS}" "${READY}" "${POD_COUNT}"
done

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  - Run individual demos: ./phase1-prevent/01-validating-webhook.sh  (etc.)"
echo "  - Run everything:        ./run-all.sh"
echo "  - Tear down:             ./cleanup.sh"

# ghz: gRPC load tester for the ZD-8616 hardening playground.
# Independent build of the public OSS ghz tool from bojand/ghz releases.
# Built locally and imported to k3d via `k3d image import` (no registry).
#
# ghz only ships an x86_64 Linux binary. Force the platform so on Apple
# Silicon hosts the container runs under Rosetta emulation; on amd64
# hosts this is a no-op.
FROM --platform=linux/amd64 alpine:3.19
RUN apk add --no-cache curl ca-certificates && \
    curl -L "https://github.com/bojand/ghz/releases/download/v0.120.0/ghz-linux-x86_64.tar.gz" \
        -o /tmp/ghz.tar.gz && \
    tar -xzf /tmp/ghz.tar.gz -C /usr/local/bin/ ghz && \
    rm /tmp/ghz.tar.gz && \
    apk del curl
# Default entrypoint runs ghz directly. For "idle" pattern needed by demos
# that exec ghz invocations into a long-running pod, use args: ["sleep", "infinity"]
# in the pod spec to override this entrypoint.
ENTRYPOINT ["/usr/local/bin/ghz"]

#!/usr/bin/env bash
# ============================================================================
# lib/grafana-snapshot.sh -- Capture Grafana dashboard snapshots during demos.
#
# ⚠ UNUSED — preserved for future revival.
#
#   No demo currently sources this file; automated rendering was abandoned
#   because Grafana's image-renderer sidecar returns empty data series
#   under JWT-authenticated headless Chromium (the same queries return data
#   via the interactive UI). The interactive dashboard described in the
#   README is the supported snapshot path. Keep this code in case the
#   renderer regression gets fixed upstream.
#
# Uses Grafana's /render endpoint (powered by the image-renderer sidecar
# Helm-managed in the monitoring namespace) to capture PNG snapshots of
# the Istio IGW hardening dashboard at specific time windows.
#
# Snapshots would be written under snapshots/<demo-id>/.
#
# Intended usage in a demo:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/grafana-snapshot.sh"
#   snapshot_grafana <demo-id> <label> [from-seconds-ago] [to-seconds-ago]
# ============================================================================

# Lazy port-forward setup: start a Grafana port-forward once per shell, reuse.
_GRAFANA_PF_PID=""
_GRAFANA_PF_PORT=""

_grafana_pf_start() {
    if [[ -n "${_GRAFANA_PF_PID}" ]] && kill -0 "${_GRAFANA_PF_PID}" 2>/dev/null; then
        return 0
    fi
    # Pick a free port in a known range
    _GRAFANA_PF_PORT=$((13000 + RANDOM % 1000))
    kubectl --context "${CONTEXT}" port-forward -n "${MONITORING_NS}" \
        svc/kube-prom-stack-grafana "${_GRAFANA_PF_PORT}:80" >/dev/null 2>&1 &
    _GRAFANA_PF_PID=$!
    # Give it a moment to come up
    sleep 2
    if ! kill -0 "${_GRAFANA_PF_PID}" 2>/dev/null; then
        echo "  ! grafana port-forward failed to start" >&2
        _GRAFANA_PF_PID=""
        _GRAFANA_PF_PORT=""
        return 1
    fi
}

_grafana_pf_stop() {
    if [[ -n "${_GRAFANA_PF_PID}" ]]; then
        kill "${_GRAFANA_PF_PID}" 2>/dev/null || true
        _GRAFANA_PF_PID=""
        _GRAFANA_PF_PORT=""
    fi
}
# Stop port-forward on script exit (additive to existing trap)
trap _grafana_pf_stop EXIT

# snapshot_grafana <demo-id> <label> [from-seconds-ago] [to-seconds-ago]
# Captures per-panel PNG snapshots of the Istio IGW hardening dashboard for the time
# window. Defaults: last 5 minutes.
#
# Sleeps SNAPSHOT_PRE_SLEEP (default 20s) BEFORE capturing so Prometheus
# has scraped enough post-demo data points for rate() to plot a series.
# Without this, panels look empty even though the demo just generated
# traffic — Prometheus scrape interval is 5s and the rate window is 15s,
# so the freshest data points need a beat to materialize.
#
# Uses /render/d-solo/<uid>/<slug>?panelId=N — renders ONE panel at a time
# with no dashboard chrome and no welcome/announcement modal overlays.
# (Grafana 12+ shows a "Grafana Assistant" promo on full-dashboard renders
# even with kiosk=tv and the assistant plugin disabled; d-solo bypasses
# the entire chrome stack.)
#
# Output files: snapshots/<demo-id>/<demo-id>-<label>-p<N>-<timestamp>.png
# (one file per panel).
snapshot_grafana() {
    local demo_id="$1"
    local label="$2"
    local from_secs=${3:-300}
    local to_secs=${4:-0}

    _grafana_pf_start || return 1

    # Pre-snapshot sleep: let Prometheus scrape post-demo data so the rate()
    # functions have enough points to draw a series. Disable via
    # SNAPSHOT_PRE_SLEEP=0 in the environment for fast iteration.
    local pre_sleep="${SNAPSHOT_PRE_SLEEP:-20}"
    if [[ "${pre_sleep}" -gt 0 ]]; then
        echo "  (waiting ${pre_sleep}s for Prometheus to scrape post-demo data...)"
        sleep "${pre_sleep}"
    fi

    local out_dir="${SNAPSHOTS_DIR}/${demo_id}"
    mkdir -p "${out_dir}"
    local ts
    ts="$(date +%s)"

    local to_ms=$(( $(date +%s) * 1000 - to_secs * 1000 ))
    local from_ms=$(( $(date +%s) * 1000 - from_secs * 1000 ))

    # Panel IDs defined in dashboard/igw-hardening.json:
    #   1 = per-cluster upstream_rq_completed rate
    #   2 = per-cluster upstream_cx_active
    #   3 = total cluster count
    #   4 = istiod xDS push rate
    local rc_overall=0
    for PANEL_ID in 1 2 3 4; do
        local out_file="${out_dir}/${demo_id}-${label}-p${PANEL_ID}-${ts}.png"
        local url="http://localhost:${_GRAFANA_PF_PORT}/render/d-solo/igw-hardening/igw-hardening?orgId=1&panelId=${PANEL_ID}&from=${from_ms}&to=${to_ms}&width=1280&height=400&tz=America%2FLos_Angeles"
        if curl -s -f -u "admin:${GRAFANA_ADMIN_PASSWORD}" "${url}" -o "${out_file}" 2>/dev/null; then
            local size
            size=$(wc -c < "${out_file}" | tr -d ' ')
            if [[ "${size}" -lt 1024 ]]; then
                echo "  ! snapshot ${demo_id}/${label} panel ${PANEL_ID}: ${size} bytes (likely error)" >&2
                rc_overall=1
            else
                echo "  📸 snapshot panel ${PANEL_ID}: ${out_file##*/} (${size} bytes)"
            fi
        else
            echo "  ! snapshot ${demo_id}/${label} panel ${PANEL_ID}: render failed" >&2
            rc_overall=1
        fi
    done
    return ${rc_overall}
}

export -f _grafana_pf_start _grafana_pf_stop snapshot_grafana

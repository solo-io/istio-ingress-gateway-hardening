# Snapshots

Manual screenshot capture target for write-up artifacts. Capture
screenshots from the interactive Grafana dashboard (see the main README's
"Operational metrics + manual snapshots" section) and save them here
organized by demo id, e.g.:

```
snapshots/
├── 13b/
│   ├── 13b-rate-shift.png
│   └── 13b-cx-active.png
├── 13c/
│   └── 13c-grpc-routing-shift.png
└── 07/
    └── 07-cluster-count-drop.png
```

This directory is intentionally empty by default. Automated rendering via
the Grafana image-renderer sidecar was attempted in deploy.sh but currently
produces empty-data PNGs (renderer-session disconnect: the headless
Chromium renders panel chrome but not data series, even though the same
queries return data via Grafana's interactive UI and the `/api/ds/query`
endpoint). The `lib/grafana-snapshot.sh` helper is preserved for future
revival; the supported snapshot path is the manual interactive flow
documented in the main README.

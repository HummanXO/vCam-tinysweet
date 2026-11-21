#!/usr/bin/env bash
# Run the OBS relay over the existing iPhone USB connection.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v iproxy >/dev/null || { echo 'iproxy is required (brew install libimobiledevice)' >&2; exit 1; }

iproxy 47110 47110 >/dev/null 2>&1 &
PROXY_PID=$!
cleanup() {
    kill "$PROXY_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
sleep 0.5
python3 "$ROOT/scripts/obs-relay.py" --iphone 127.0.0.1 "$@"

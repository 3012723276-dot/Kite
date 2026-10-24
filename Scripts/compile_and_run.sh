#!/bin/bash
# Kills running instances, rebuilds the app bundle, and relaunches it.
# Usage: Scripts/compile_and_run.sh [debug|release]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF="${1:-debug}"
APP_BUNDLE="$ROOT/.build/app/Kite.app"

# Kill running instances
for _ in $(seq 1 25); do
  pgrep -x Kite >/dev/null 2>&1 || break
  pkill -x Kite 2>/dev/null || true
  sleep 0.2
done
pkill -9 -x Kite 2>/dev/null || true

"$SCRIPT_DIR/build-app.sh" "$CONF"

open "$APP_BUNDLE"

# Verify it stayed up
for _ in $(seq 1 20); do
  sleep 0.2
  if pgrep -x Kite >/dev/null 2>&1; then
    echo "Kite is running."
    exit 0
  fi
done
echo "ERROR: Kite did not stay running — check Console.app for crash logs." >&2
exit 1

#!/bin/bash
# Installs the notarized build/export/Transmission Remote.app into
# /Applications, replacing any existing copy. Quits a running instance first
# (matched by bundle path, never the Debug build — see CLAUDE.md gotcha 4).
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

src_app="build/export/Transmission Remote.app"
dest_app="/Applications/Transmission Remote.app"

if [[ ! -d "$src_app" ]]; then
  echo "error: $src_app not found — run scripts/build_release.sh (+ notarize.sh) first" >&2
  exit 1
fi

if pgrep -f "${dest_app}/Contents/MacOS/Transmission Remote" >/dev/null 2>&1; then
  echo "==> quitting running /Applications instance"
  osascript -e 'tell application "Transmission Remote" to quit' 2>/dev/null || true
  pkill -f "${dest_app}/Contents/MacOS/Transmission Remote" 2>/dev/null || true
  sleep 1
fi

echo "==> installing to $dest_app"
rm -rf "$dest_app"
ditto "$src_app" "$dest_app"

echo "==> installed: $dest_app"

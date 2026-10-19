#!/usr/bin/env bash
# Render a real client's loading cover and the frame after it lifts, against a real server in a
# second process. Look at screenshots/cover_up.png, cover_lifted.png and cover_after_1s.png.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots
exec xvfb-run -a "${GODOT:-godot}" --path . --resolution 1280x720 res://tools/render_cover.tscn

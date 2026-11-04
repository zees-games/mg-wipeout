#!/bin/bash
# Publishes this game's pack (id mg-wipeout). The courses, worlds, cfg and art libraries are links to mg-wipeout-maps, its own pack; screenshots are not
# runtime content. Host addons come from the server (--host-addons).
#   tools/publish.sh [--version V | --bump patch] [--site URL --token-file F --dry-run ...]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$HERE/../dot-cloud/tools/publish_pack.sh" publish --source "$HERE" --id mg-wipeout \
    --host-addons "$HERE/../dot-server-deploy/addons.lock" --exclude-dir courses --exclude-dir cfg --exclude-dir worlds \
    --exclude-dir model-library --exclude-dir pbr-library --exclude-dir screenshots \
    --lock "$HERE/content.lock.json" "$@"

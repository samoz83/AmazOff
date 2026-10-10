#!/bin/sh
# Download each distinct upstream player bundle and generate its no-ads patch.
# wave1..wave3 currently serve the same bundle, so wave1 is built for all wave routes.
# onebox2 (older 2.7MB player) is not routed by nginx and is not patched.
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
BASE_URL="https://cloudfront.xp-assets.aiv-cdn.net/family/lg/ATVUnfPlayerBundle-1.0"
WORK_DIR="${1:-$(mktemp -d "${TMPDIR:-/tmp}/amazoff-upstream.XXXXXX")}"

for route in onebox1 wave1; do
  url="$BASE_URL/$route/js/ATVUnfPlayerBundle.js"
  curl -fsSL "$url" -o "$WORK_DIR/$route.js"
  node "$ROOT_DIR/development/amazon/build-patch.js" \
    --source "$WORK_DIR/$route.js" --source-url "$url" --route "$route" \
    --out-dir "$ROOT_DIR/resources/amazon/patch/$route"
done

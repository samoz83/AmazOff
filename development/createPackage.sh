#!/bin/sh
# Package only what ships, so repo-only files stay out without -e rules.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cd "$ROOT"
cp -R appinfo.json index.html amazoff.png amazoffLarge.png LICENSE assets css js resources tools "$STAGE/"
find "$STAGE" -name .DS_Store -delete
ares-package --no-minify -o "$ROOT/development" "$STAGE"
sha256sum "$ROOT"/development/com.amazoff*

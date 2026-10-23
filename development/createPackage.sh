#!/bin/sh
# Package only what ships, so repo-only files stay out without -e rules.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d)"
CHECK="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$CHECK"' EXIT
cd "$ROOT"
cp -R appinfo.json index.html amazoff.png amazoffLarge.png LICENSE assets css js resources tools "$STAGE/"
find "$STAGE" -name .DS_Store -delete
ares-package --no-minify -o "$ROOT/development" "$STAGE"
VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' appinfo.json)"
IPK="com.amazoff.patcher_${VERSION}_all.ipk"

# The IPK must hold exactly the staged files, unminified and still executable.
(cd "$CHECK" && ar x "$ROOT/development/$IPK" && tar xzf data.tar.gz)
APP="$CHECK/usr/palm/applications/com.amazoff.patcher"
diff -r "$STAGE" "$APP"
for f in tools/*.sh tools/nginx/nginx; do [ -x "$APP/$f" ] || { echo "not executable in IPK: $f" >&2; exit 1; }; done
sh development/amazon/prepareRelease.sh "$APP/resources/amazon/patch" >/dev/null

# Homebrew Channel manifest for the release; ipkHash must match the IPK or installs fail.
HASH="$(sha256sum "development/$IPK" | cut -d' ' -f1)"
printf '{"id":"com.amazoff.patcher","version":"%s","type":"native","title":"AmazOff Patcher","appDescription":"Amazon Prime Video Patcher","iconUri":"https://github.com/samoz83/AmazOff/blob/master/amazoffLarge.png?raw=true","sourceUrl":"https://github.com/samoz83/AmazOff","rootRequired":true,"ipkUrl":"%s","ipkHash":{"sha256":"%s"}}\n' \
  "$VERSION" "$IPK" "$HASH" > development/org.webosbrew.manifest.json
echo "$HASH  $IPK"

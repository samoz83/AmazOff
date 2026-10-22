#!/bin/sh
# Compare each player bundle Amazon serves with the source our patch was built from.
# Routes and the patch dir serving each come from nginx.conf.
# Exit 0: all match. 1: a bundle changed, rerun setupDev.sh. 2: a download failed.
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
BASE_URL="https://cloudfront.xp-assets.aiv-cdn.net/family/lg/ATVUnfPlayerBundle-1.0"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
rc=0

for pair in $(awk '
  /location = \/family\/lg\/ATVUnfPlayerBundle-1.0\// { split($3, p, "/"); route = p[5] }
  /try_files/ && route { split($2, p, "/"); print route ":" p[2]; route = "" }
' "$ROOT_DIR/resources/amazon/config/nginx.conf"); do
  route="${pair%%:*}"
  dir="${pair#*:}"
  want="$(sed -n 's/.*"sourceSha256": *"\([0-9a-f]*\)".*/\1/p' "$ROOT_DIR/resources/amazon/patch/$dir/manifest.json")"
  code="$(curl -sSL -o "$TMP" -w '%{http_code}' "$BASE_URL/$route/js/ATVUnfPlayerBundle.js" || true)"
  case "$code" in
    200) ;;
    403|404) echo "$route: not served upstream ($code)"; continue ;;
    *) echo "$route: download failed (HTTP $code)"; rc=2; continue ;;
  esac
  got="$(shasum -a 256 "$TMP" | cut -d' ' -f1)"
  if [ "$got" = "$want" ]; then
    echo "$route: ok $got"
  else
    echo "$route: CHANGED, live $got, patched from $want ($dir)"
    [ "$rc" -eq 2 ] || rc=1
  fi
done

exit "$rc"

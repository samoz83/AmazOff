#!/bin/sh
# Check every packaged bundle still matches its manifest (catches minification by ares-package).
set -eu

PATCH_DIR="${1:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)/resources/amazon/patch}"
for manifest in "$PATCH_DIR"/*/manifest.json; do
  node -e 'const fs=require("fs"),c=require("crypto"),p=require("path");const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const got=c.createHash("sha256").update(fs.readFileSync(p.join(p.dirname(process.argv[1]),"ATVUnfPlayerBundle.js"))).digest("hex");if(got!==m.patchedSha256)throw new Error(m.route+": patched hash mismatch "+got);console.log(m.route+": ok "+got)' "$manifest"
done

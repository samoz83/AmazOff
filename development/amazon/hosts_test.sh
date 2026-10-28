#!/bin/sh
# Tests the hosts-file helpers in tools/lib/patch.sh against a temp tree. Run from anywhere.
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

CERT_DIR="$T" TARGET_DIR="$T" TARGET_APP_NAME=amazon
log() { :; }
die() { echo "die: $*"; exit 1; }
. "$ROOT_DIR/tools/lib/patch.sh"
HOSTS_SYSTEM="$T/hosts" HOSTS_JAIL="$T/jail/hosts"
unpatch_rootfs_hosts() { :; }

fail() { echo "FAIL: $*"; exit 1; }

cat >"$HOSTS_SYSTEM" <<'EOF'
127.0.0.1 localhost
0.0.0.0 ads.example.com
# 0.0.0.0 cloudfront.xp-assets.aiv-cdn.net
0.0.0.0 tracker.example CloudFront.XP-assets.aiv-cdn.net # blocklist
EOF
before="$(cat "$HOSTS_SYSTEM")"

patch_hosts
patch_hosts
hosts_patched || fail "entry missing after patch"
[ "$(grep -cxF "$HOST_ENTRY" "$HOSTS_SYSTEM")" = 1 ] || fail "patch is not idempotent"
grep -qxF "$HOST_ENTRY_V6" "$HOSTS_JAIL" || fail "v6 entry missing in new jail file"

[ "$(hosts_conflicts)" = "0.0.0.0 tracker.example CloudFront.XP-assets.aiv-cdn.net # blocklist" ] ||
  fail "conflicts: got '$(hosts_conflicts)'"

unpatch_hosts
! hosts_patched || fail "entry left after unpatch"
# patch adds blank separator lines; every other line must survive unchanged
[ "$(grep -v '^$' "$HOSTS_SYSTEM")" = "$before" ] || fail "unpatch changed other lines"
[ -z "$(hosts_conflicts | grep -v tracker.example)" ] || fail "unexpected conflicts"

# webOS 10 C4: Stop/rollback on a read-only hosts without our entry must not die
chmod a-w "$HOSTS_SYSTEM"
( unpatch_hosts ) || fail "unpatch died on read-only hosts without our entry"
chmod u+w "$HOSTS_SYSTEM"
rm "$HOSTS_JAIL"
( unpatch_hosts ) || fail "unpatch died on missing jail hosts"

# Read-only /etc/hosts: Start mounts a writable copy over it. Root ignores chmod, so skip the asserts there.
export TMPDIR="$T"
mount() { : >"$T/mounted"; chmod u+w "$3"; }
chmod a-w "$HOSTS_SYSTEM"
( patch_hosts ) || fail "patch died on read-only hosts"
[ "$(id -u)" = 0 ] || [ -f "$T/mounted" ] || fail "no writable copy mounted over read-only hosts"
hosts_patched || fail "entry missing after mounting a writable copy"

# If the mount fails too, Start must still patch the jail and leave the failure to the state check.
unpatch_hosts
mount() { return 1; }
chmod a-w "$HOSTS_SYSTEM"
( patch_hosts ) || fail "patch died when the mount failed"
grep -qxF "$HOST_ENTRY" "$HOSTS_JAIL" || fail "jail not patched when the mount failed"
chmod u+w "$HOSTS_SYSTEM"

echo "hosts_test: ok"

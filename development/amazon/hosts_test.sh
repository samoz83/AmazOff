#!/bin/sh
# Tests the hosts-file and CA pin helpers in tools/lib/patch.sh against a temp tree. Run from anywhere.
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

CERT_DIR="$T" TARGET_DIR="$T" TARGET_APP_NAME=amazon
echo ours >"$T/ca.0"   # CERT_NAME comes from this when patch.sh is sourced
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
grep -vxF "$HOST_ENTRY_V6" "$HOSTS_JAIL" >"$T/j" && cat "$T/j" >"$HOSTS_JAIL"
! hosts_patched || fail "patched state accepted without the v6 entry"
patch_hosts
hosts_patched || fail "v6 entry not restored"

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

# CA pin. webOS 11 at boot: no bin/certs and no overlay upper dir. Start must not die, and the
# running state must accept it so the monitor can pin later.
UPPER_CERT_DIR="$T/upper/bin/certs"
require_root() { :; }
toast() { :; }
( do_patch ) >/dev/null || fail "Start died with nowhere to pin the CA"
( patch_cert_pin ) || fail "Start would stop with nowhere to pin the CA"
cert_deferred && cert_ok && ! cert_pinned || fail "nothing to pin into: want deferred, not pinned"
patch_default_conf
[ ! -f "$T/default_config.json" ] || fail "config written into an unmounted app dir"

# Overlay unmounted but its upper dir exists: pin there, and Stop removes it.
mkdir -p "$UPPER_CERT_DIR"
patch_cert_pin || fail "pin into the upper dir failed"
[ -f "$UPPER_CERT_DIR/ca.0" ] && cert_pinned && ! cert_deferred || fail "CA not pinned in the upper dir"
do_unpatch >/dev/null
[ ! -f "$UPPER_CERT_DIR/ca.0" ] || fail "Stop left the CA in the upper dir"

# Mounted: pin into bin/certs, and leave the upper dir alone (changing it under a mount is undefined).
mkdir -p "$TARGET_DIR/bin/certs"
cp "$T/ca.0" "$UPPER_CERT_DIR/ca.0"
ln -s "$T/planted" "$TARGET_DIR/bin/certs/ca.0"
! ( patch_cert_pin ) && [ ! -e "$T/planted" ] || fail "pin followed a symlink"
rm "$TARGET_DIR/bin/certs/ca.0"
echo stale >"$TARGET_DIR/bin/certs/ca.0"
! cert_pinned || fail "a different file with our CA's name counted as pinned"
patch_cert_pin && cmp -s "$TARGET_DIR/bin/certs/ca.0" "$T/ca.0" || fail "CA not pinned or not replaced in bin/certs"
do_unpatch >/dev/null
[ ! -f "$TARGET_DIR/bin/certs/ca.0" ] || fail "Stop left the CA in bin/certs"
[ -f "$UPPER_CERT_DIR/ca.0" ] || fail "Stop changed the upper dir while mounted"
! cert_pinned && ! cert_ok || fail "bin/certs without the CA must not count as running"

# Config: absent (overlay unmounted) or ours counts as patched; the stock one doesn't.
CONFIGS_DIR="$T/conf"; mkdir -p "$CONFIGS_DIR"; echo ours >"$CONFIGS_DIR/default_config.json"
rm -f "$T/default_config.json"; conf_ok || fail "missing config must not count as unpatched"
echo stock >"$T/default_config.json"; ! conf_ok || fail "stock config counted as patched"
patch_default_conf && conf_ok || fail "config not patched"
# A failed backup leaves the config alone, so Stop can still restore the original.
rm -f "$T/default_config.json.bak"; echo stock >"$T/default_config.json"
(
  cp() { : >"$2"; return 1; }   # a full disk leaves a truncated copy
  ! patch_default_conf || fail "config patched without a backup"
  [ "$(cat "$T/default_config.json")" = stock ] && [ ! -e "$T/default_config.json.bak" ] ||
    fail "config changed or truncated backup left"
  echo '{"disable-ssl-cert":true}' >"$T/default_config.json"
  patch_default_conf && conf_ok || fail "disable-ssl-cert config kept for want of a backup"
) || exit 1

# Stop also cleans the rootfs /etc/hosts hidden under a bind-mounted table (unpatch_rootfs_hosts).
# Fake /proc/mounts, mount and umount; the rest is the real code. Subshell so the fakes don't leak.
(
  . "$ROOT_DIR/tools/lib/patch.sh"
  HOSTS_SYSTEM="$T/visible" HOSTS_JAIL="$T/jail/hosts"
  clean="127.0.0.1 localhost
0.0.0.0 other.example"
  for f in "$HOSTS_SYSTEM" "$HOSTS_JAIL" "$T/hidden"; do
    printf '%s\n%s\n%s\n' "$clean" "$HOST_ENTRY" "$HOST_ENTRY_V6" >"$f"
  done
  bound=no
  grep() { if [ "$3" = /proc/mounts ]; then [ "$2" = " /etc/hosts " ] && [ $bound = yes ]; return; fi; command grep "$@"; }
  mount() { [ "$1 $2" = "--bind /" ] || fail "unexpected mount args: $*"; mkdir -p "$3/etc"; cp "$T/hidden" "$3/etc/hosts"; }
  umount() { cp "$1/etc/hosts" "$T/hidden" && rm -r "$1/etc" && : >"$T/released"; }
  # No table mounted over /etc/hosts: nothing hidden to clean.
  unpatch_rootfs_hosts
  grep -qxF "$HOST_ENTRY" "$T/hidden" || fail "rootfs hosts changed with no bind mount"
  bound=yes
  unpatch_hosts
  for f in "$HOSTS_SYSTEM" "$HOSTS_JAIL" "$T/hidden"; do
    [ "$(cat "$f")" = "$clean" ] || fail "redirect left in $f"
  done
  [ -f "$T/released" ] || fail "rootfs view not unmounted"
) || exit 1

# webOS 3 (lovefilm): Start checks every file exists before overwriting any of them.
CONFIGS_DIR="$T/lf/conf" PATCHER_RESOURCES_DIR="$T/lf/res"
mkdir -p "$CONFIGS_DIR" "$PATCHER_RESOURCES_DIR/patch" "$(dirname "$TARGET_CONF_LOVEFILM")" "$(dirname "$TARGET_CHUNK_LOVEFILM")"
echo ours >"$CONFIGS_DIR/ignition-config.txt"
for missing in "$CONFIGS_DIR/ignition-config.txt" "$PATCHER_RESOURCES_DIR/patch/chunk-0.js" "$TARGET_CONF_LOVEFILM" "$TARGET_CHUNK_LOVEFILM"; do
  echo ours >"$CONFIGS_DIR/ignition-config.txt"; echo ours >"$PATCHER_RESOURCES_DIR/patch/chunk-0.js"
  echo stock >"$TARGET_CONF_LOVEFILM"; echo stock >"$TARGET_CHUNK_LOVEFILM"
  rm "$missing"
  ! ( do_patch_lovefilm ) >/dev/null || fail "lovefilm Start went on without $missing"
  for t in "$TARGET_CONF_LOVEFILM" "$TARGET_CHUNK_LOVEFILM"; do
    [ "$t" = "$missing" ] || [ "$(cat "$t")" = stock ] || fail "$t overwritten before the check"
  done
done
echo stock >"$TARGET_CONF_LOVEFILM"; echo stock >"$TARGET_CHUNK_LOVEFILM"
( do_patch_lovefilm ) >/dev/null && is_lovefilm_patched || fail "lovefilm not patched"
[ "$(cat "$TARGET_CHUNK_LOVEFILM.bak")" = stock ] || fail "lovefilm backup missing"

echo "hosts_test: ok"

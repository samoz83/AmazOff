#!/bin/sh
TARGET_CERT_DIR="$TARGET_DIR/bin/certs"
TARGET_CERT_DIR_LOVEFILM="$TARGET_DIR/plugins/com.amazon.ignition.framework.network/static/0.6.5/certs/ca-certs"
TARGET_CONF_LOVEFILM="$TARGET_DIR/plugins/com.amazon.ignition.framework.core/static/0.22.11/ignition-config.txt"
TARGET_CHUNK_LOVEFILM="$TARGET_DIR/plugins/com.amazon.ignition.app.stark/var/chunks-cache/chunk-0.js"
# AmazOff's own CA, constrained to the bundle host. Lovefilm needs no CA: its patch is a file on disk.
CERT_NAME="$(basename "$(ls "$CERT_DIR"/*.0 2>/dev/null | head -n 1)")"
OLD_CERT_NAME="fe1de658.0"   # goproxy CA pinned for Amazon <= 0.2.3, lovefilm <= 0.2.5; its private key is public
HOSTS_JAIL="/mnt/lg/user/var/palm/jail/$TARGET_APP_NAME/etc/hosts"
HOSTS_SYSTEM="/etc/hosts"
HOST_ENTRY="127.0.0.1 cloudfront.xp-assets.aiv-cdn.net"
HOST_ENTRY_V6="::1 cloudfront.xp-assets.aiv-cdn.net"
# webOS 11 mounts the app as an overlay only while it runs, and files added to it persist in this upper
# layer. The path comes from upstream PR #18, seen on one webOS 11.2 TV. Code that uses it checks it exists.
UPPER_CERT_DIR="/media/data/data/$TARGET_APP_NAME/bin/certs"

# True when there is nowhere to pin the CA yet. bin/certs is missing while the webOS 11 overlay is
# unmounted, for example at boot, and during an app update. The monitor pins the CA once it's back.
cert_deferred() {
  [ ! -d "$TARGET_CERT_DIR" ] && [ ! -d "$UPPER_CERT_DIR" ]
}

# Returns 1 only when pinning fails. With nowhere to pin yet it returns 0, so Start goes on and the monitor pins later.
patch_cert_pin() {
  d="$TARGET_CERT_DIR"
  if [ ! -d "$d" ]; then
    # The kernel allows changes to an overlay's upper layer while it's unmounted.
    [ -d "$UPPER_CERT_DIR" ] || { log "CA pin deferred: $TARGET_CERT_DIR not mounted; the monitor adds it when Prime Video opens"; return 0; }
    d="$UPPER_CERT_DIR"
  fi
  if [ -f "$d/$OLD_CERT_NAME" ]; then
    rm -f "$d/$OLD_CERT_NAME"
    log "Removed old goproxy CA"
  fi
  # The app's user may be able to write here, and a dangling link would make root's cp create its target.
  [ -L "$d/$CERT_NAME" ] && { log "WARNING: $d/$CERT_NAME is a symlink, not pinning"; return 1; }
  if ! cmp -s "$d/$CERT_NAME" "$CERT_DIR/$CERT_NAME"; then
    cp "$CERT_DIR/$CERT_NAME" "$d/$CERT_NAME" || { log "WARNING: could not place CA in $d"; return 1; }
    chmod 755 "$d/$CERT_NAME" 2>/dev/null || true
    log "Placed CA cert in $d"
  else
    log "CA already in place"
  fi
}

patch_lovefilm_conf(){
  [ -f "$TARGET_CONF_LOVEFILM.bak" ] || cp "$TARGET_CONF_LOVEFILM" "$TARGET_CONF_LOVEFILM.bak" 2>/dev/null
  cat "$CONFIGS_DIR/ignition-config.txt" > "$TARGET_CONF_LOVEFILM"
}

patch_lovefilm_chunk(){
  [ -f "$TARGET_CHUNK_LOVEFILM.bak" ] || cp "$TARGET_CHUNK_LOVEFILM" "$TARGET_CHUNK_LOVEFILM.bak" 2>/dev/null
  cat "$PATCHER_RESOURCES_DIR/patch/chunk-0.js" > "$TARGET_CHUNK_LOVEFILM"
}

patch_default_conf(){
  # Not there while the webOS 11 overlay is unmounted; writing it would land in the bare mountpoint.
  [ -f "$TARGET_DIR/default_config.json" ] || return 0
  [ -f "$TARGET_DIR/default_config.json.bak" ] || cp "$TARGET_DIR/default_config.json" "$TARGET_DIR/default_config.json.bak" 2>/dev/null
  cat "$CONFIGS_DIR/default_config.json" > "$TARGET_DIR/default_config.json"
}

patch_hosts(){
  writable_system_hosts
  patch_hosts_helper "$HOSTS_SYSTEM" && log "Patched system hosts" || log "WARNING: could not write $HOSTS_SYSTEM"
  patch_hosts_helper "$HOSTS_JAIL"
  log "Patched jail hosts"
}

unpatch_hosts(){
  unpatch_hosts_helper "$HOSTS_SYSTEM"
  log "Unpatched system hosts"
  unpatch_hosts_helper "$HOSTS_JAIL"
  log "Unpatched jail hosts"
  unpatch_rootfs_hosts
}

# Glasshouse >= 0.100 copies other tools' lines from the /etc/hosts underneath its
# table into the table at boot, so an entry left in the rootfs file would come back.
# ponytail: rootfs layer only; HBC's layer is /tmp/hosts and gone at reboot.
unpatch_rootfs_hosts() {
  grep -q ' /etc/hosts ' /proc/mounts 2>/dev/null || return 0
  root="$(mktemp -d)" || return 0
  mount --bind / "$root" 2>/dev/null || { rmdir "$root"; return 0; }
  if grep -qxF -e "$HOST_ENTRY" -e "$HOST_ENTRY_V6" "$root/etc/hosts" 2>/dev/null; then
    # Read-only rootfs (e.g. C4 on webOS 10.3.1) can't hold our entry anyway; don't let die abort Stop.
    ( unpatch_hosts_helper "$root/etc/hosts" ) >/dev/null && log "Unpatched rootfs hosts"
  fi
  umount "$root" 2>/dev/null
  rmdir "$root" 2>/dev/null
}

# Some TVs, such as a C4 on webOS 10.3.1, have a read-only /etc/hosts unless HBC's "Block system
# updates" has bind-mounted a copy over it. Do the same. Stop leaves the copy mounted until reboot.
writable_system_hosts() {
  # busybox `test -w` is always true for root, even on a read-only filesystem, so try a real open.
  # printf, not `:`: a redirect error on a special builtin exits busybox ash.
  printf '' 2>/dev/null >>"$HOSTS_SYSTEM" && return 0
  # A fresh mktemp file, not one in /tmp/patcher: another user could have created that dir first.
  h="$(mktemp)" && cat "$HOSTS_SYSTEM" >"$h" && chmod 644 "$h" && mount --bind "$h" "$HOSTS_SYSTEM" &&
    log "Mounted a writable copy over $HOSTS_SYSTEM"
}

patch_hosts_helper() {
  f="$1"
  d="$(dirname "$f")"

  mkdir -p "$d" || die "mkdir failed: $d"
  [ -f "$f" ] || : >"$f" || die "create failed: $f"

  awk -v line="$HOST_ENTRY" '
    $0 == line { found=1 }
    END { exit (found ? 0 : 1) }
  ' "$f" || printf '\n%s\n' "$HOST_ENTRY" >>"$f" || return 1

  awk -v line="$HOST_ENTRY_V6" '
    $0 == line { found=1 }
    END { exit (found ? 0 : 1) }
  ' "$f" || printf '\n%s\n' "$HOST_ENTRY_V6" >>"$f"
}

unpatch_hosts_helper() {
  f="$1"
  # If there's nothing to remove, don't write, so Stop and rollback get past a read-only or missing file.
  grep -qxF -e "$HOST_ENTRY" -e "$HOST_ENTRY_V6" "$f" 2>/dev/null || return 0

  tmp="$(mktemp)" || die "mktemp failed"
  awk -v l4="$HOST_ENTRY" -v l6="$HOST_ENTRY_V6" '$0 != l4 && $0 != l6 { print }' "$f" >"$tmp" || die "write tmp failed: $tmp"
  cat "$tmp" > "$f" || { rm -f "$tmp"; die "replace failed: $f"; }
  rm -f "$tmp"
}

manifest_field() {
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
}

# An Amazon app update replaces bin/certs; without the pin, TLS to nginx fails.
cert_pinned() {
  cmp -s "$TARGET_CERT_DIR/$CERT_NAME" "$CERT_DIR/$CERT_NAME" ||
    { [ ! -d "$TARGET_CERT_DIR" ] && cmp -s "$UPPER_CERT_DIR/$CERT_NAME" "$CERT_DIR/$CERT_NAME"; }
}

# Our config, or none while the webOS 11 overlay is unmounted. It only sets the log level, so the
# running state ignores it, but it replaces an upstream config with disable-ssl-cert.
conf_ok() {
  [ ! -f "$TARGET_DIR/default_config.json" ] || cmp -s "$TARGET_DIR/default_config.json" "$CONFIGS_DIR/default_config.json"
}

# For the running state: pinned, or waiting for bin/certs, which the monitor handles.
cert_ok() {
  cert_pinned || cert_deferred
}

# Another hosts manager (e.g. an ad blackhole tool) can rewrite these files and drop our entry.
# Without the ::1 line, an IPv6 lookup can still reach the real CDN.
hosts_patched() {
  for f in "$HOSTS_SYSTEM" "$HOSTS_JAIL"; do
    grep -qxF "$HOST_ENTRY" "$f" 2>/dev/null && grep -qxF "$HOST_ENTRY_V6" "$f" 2>/dev/null || return 1
  done
}

# Lines not ours that also map our host, e.g. a Glasshouse uploaded blocklist sinkholing it.
# They precede our entry in the table, so they win and the player bundle never reaches nginx.
hosts_conflicts() {
  host="${HOST_ENTRY#* }"
  for f in "$HOSTS_SYSTEM" "$HOSTS_JAIL"; do
    [ -f "$f" ] || continue
    awk -v h="$host" -v l4="$HOST_ENTRY" -v l6="$HOST_ENTRY_V6" '
      $0 == l4 || $0 == l6 || $1 ~ /^#/ { next }
      { for (i = 2; i <= NF && $i !~ /^#/; i++) if (tolower($i) == h) { print; next } }
    ' "$f"
  done | sort -u
}

warn_hosts_conflicts() {
  c="$(hosts_conflicts)"
  [ -n "$c" ] || return 1
  log "WARNING: another hosts entry overrides AmazOff (remove it from your ad blocker's list):
$c"
}

do_patch() {
  require_root
  log "patching target=$TARGET_DIR"
  patch_default_conf
  patch_cert_pin || return 1
  patch_hosts
  warn_hosts_conflicts && toast "AmazOff: blocked by another hosts entry, see Details"
  log "Successfully patched"
}

do_patch_lovefilm() {
  require_root
  log "patching target=$TARGET_DIR"
  # cat src > dst empties dst before reading src, so check every file before writing any
  for f in "$CONFIGS_DIR/ignition-config.txt" "$PATCHER_RESOURCES_DIR/patch/chunk-0.js" \
           "$TARGET_CONF_LOVEFILM" "$TARGET_CHUNK_LOVEFILM"; do
    [ -f "$f" ] || die "Missing $f"
  done
  rm -f "$TARGET_CERT_DIR_LOVEFILM/$OLD_CERT_NAME" 2>/dev/null || true
  patch_lovefilm_conf
  patch_lovefilm_chunk
  log "Successfully patched"
}

do_unpatch_lovefilm() {
  require_root
  log "unpatch started: target=$TARGET_DIR"
  rm -f "$TARGET_CERT_DIR_LOVEFILM/$OLD_CERT_NAME" 2>/dev/null || true
  log "removed Cert pinning"

  rm -f "$TARGET_CONF_LOVEFILM" 2>/dev/null || true
  if [ -f "$TARGET_CONF_LOVEFILM.bak" ]; then
    cat "$TARGET_CONF_LOVEFILM.bak" > "$TARGET_CONF_LOVEFILM"
    rm -f "$TARGET_CONF_LOVEFILM.bak" 2>/dev/null || true
    log "restored default_config"
  fi

  rm -f "$TARGET_CHUNK_LOVEFILM" 2>/dev/null || true
  if [ -f "$TARGET_CHUNK_LOVEFILM.bak" ]; then
    cat "$TARGET_CHUNK_LOVEFILM.bak" > "$TARGET_CHUNK_LOVEFILM"
    rm -f "$TARGET_CHUNK_LOVEFILM.bak" 2>/dev/null || true
    log "restored js resource"
  else
    log "removed js patch"
  fi
  log "Successfully unpatched"
}

is_lovefilm_patched() {
  cmp -s "$TARGET_CHUNK_LOVEFILM" "$PATCHER_RESOURCES_DIR/patch/chunk-0.js"
}

do_unpatch() {
  require_root
  log "unpatch started: target=$TARGET_DIR"
  rm -f "$TARGET_CERT_DIR/$CERT_NAME" "$TARGET_CERT_DIR/$OLD_CERT_NAME" 2>/dev/null || true
  # Only while unmounted: changing the upper layer under a mounted overlay is undefined.
  [ -d "$TARGET_CERT_DIR" ] || rm -f "$UPPER_CERT_DIR/$CERT_NAME" "$UPPER_CERT_DIR/$OLD_CERT_NAME" 2>/dev/null
  log "removed Cert pinning"
  if [ -f "$TARGET_DIR/default_config.json.bak" ]; then
    # AmazOff <= 0.2.5 wrote disable-ssl-cert (turns off TLS checks app-wide); a .bak taken after that keeps it.
    grep -q '"disable-ssl-cert"' "$TARGET_DIR/default_config.json.bak" ||
      cat "$TARGET_DIR/default_config.json.bak" > "$TARGET_DIR/default_config.json"
    rm -f "$TARGET_DIR/default_config.json.bak" 2>/dev/null || true
    log "restored default_config"
  fi
  # Last, because it's the step that can die, for example when our entry is in a read-only layer.
  unpatch_hosts
  log "Successfully unpatched"
}


patch_status_log() {
  log ""
  log "---- PATCH INFO ----"
  log "targetAppName: $TARGET_APP_NAME"
  log "targetAppDir: $TARGET_DIR"
  for m in "$PATCHER_RESOURCES_DIR"/patch/*/manifest.json; do
    [ -f "$m" ] && log "$(manifest_field "$m" route): source $(manifest_field "$m" sourceSha256) patched $(manifest_field "$m" patchedSha256)"
  done
  if [ "$TARGET_APP_NAME" = "$APP_NAME_AMAZON" ]; then
    if cert_pinned; then
      log "CA in place"
    elif cert_deferred; then
      log "CA waiting: $TARGET_CERT_DIR isn't there (webOS 11 with Prime Video closed, or an app update). The monitor adds it when it appears."
    else
      log "WARNING: CA missing or out of date in the Amazon app (app updated?). Press Start again."
    fi
  fi
  if [ -f "$BASE/autostart.log" ]; then
    log "--------"
    log "Last autostart at boot:
$(cat "$BASE/autostart.log")"
  fi
  hosts_patched || log "WARNING: hosts override missing; another tool may have rewritten hosts. Press Start again."
  warn_hosts_conflicts
  log "--------"
  log "$HOSTS_SYSTEM:
$(cat $HOSTS_SYSTEM)"
  log "--------"
  log "$HOSTS_JAIL:
$(cat $HOSTS_JAIL)"
  log "--------"
}

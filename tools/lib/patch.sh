#!/bin/sh
TARGET_CERT_DIR="$TARGET_DIR/bin/certs"
TARGET_CERT_DIR_LOVEFILM="$TARGET_DIR/plugins/com.amazon.ignition.framework.network/static/0.6.5/certs/ca-certs"
TARGET_CONF_LOVEFILM="$TARGET_DIR/plugins/com.amazon.ignition.framework.core/static/0.22.11/ignition-config.txt"
TARGET_CHUNK_LOVEFILM="$TARGET_DIR/plugins/com.amazon.ignition.app.stark/var/chunks-cache/chunk-0.js"
# Amazon: AmazOff's own CA, constrained to the bundle host. Lovefilm still uses the goproxy CA.
CERT_NAME="$(basename "$(ls "$CERT_DIR"/*.0 | head -n 1)")"
OLD_CERT_NAME="fe1de658.0"   # goproxy CA pinned by AmazOff <= 0.2.3; its private key is public
HOSTS_JAIL="/mnt/lg/user/var/palm/jail/$TARGET_APP_NAME/etc/hosts"
HOSTS_SYSTEM="/etc/hosts"
HOST_ENTRY="127.0.0.1 cloudfront.xp-assets.aiv-cdn.net"
HOST_ENTRY_V6="::1 cloudfront.xp-assets.aiv-cdn.net"

patch_cert_pin() {
  if [ -d  $TARGET_CERT_DIR ]; then
    if [ -f "$TARGET_CERT_DIR/$OLD_CERT_NAME" ]; then
      rm -f "$TARGET_CERT_DIR/$OLD_CERT_NAME"
      log "Removed old goproxy CA"
    fi
    if [ ! -f "$TARGET_CERT_DIR/$CERT_NAME" ]; then
      cp "$CERT_DIR/$CERT_NAME" "$TARGET_CERT_DIR/$CERT_NAME"
      chmod 755 "$TARGET_CERT_DIR/$CERT_NAME" 2>/dev/null || true
      log "Placed CA cert"
    else
      log "CA already in place"
    fi
  elif [ -d  $TARGET_CERT_DIR_LOVEFILM ]; then
    if [ ! -f "$TARGET_CERT_DIR_LOVEFILM/$CERT_NAME" ]; then
      cp "$CERT_DIR/$CERT_NAME" "$TARGET_CERT_DIR_LOVEFILM/$CERT_NAME"
      chmod 755 "$TARGET_CERT_DIR_LOVEFILM/$CERT_NAME" 2>/dev/null || true
      log "Placed CA cert for lovefilm"
    else
      log "CA already in place"
    fi
  else
    die "No cert directory found!"
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
  [ -f "$TARGET_DIR/default_config.json.bak" ] || cp "$TARGET_DIR/default_config.json" "$TARGET_DIR/default_config.json.bak" 2>/dev/null
  cat "$CONFIGS_DIR/default_config.json" > "$TARGET_DIR/default_config.json"
}

patch_debug_conf(){
  [ -f "$TARGET_DIR/default_config.json.bak" ] || cp "$TARGET_DIR/default_config.json" "$TARGET_DIR/default_config.json.bak" 2>/dev/null
  cat "$CONFIGS_DIR/default_config_debug.json" > "$TARGET_DIR/default_config.json"
  log "Patched Debug config"
  mkdir -m 777 -p "$TARGET_DIR/logs" 2>/dev/null || true
}

patch_debug_certs(){
  cp -r "$TOOLS_DIR/mitm/certcache" "$LOGS_BASE_DIR" 2>/dev/null || true
  log "Preload certs"
}

patch_hosts(){
  patch_hosts_helper "$HOSTS_SYSTEM"
  log "Patched system hosts"
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
  root="/tmp/amazoff-root.$$"
  mkdir -p "$root" && mount --bind / "$root" 2>/dev/null || { rmdir "$root" 2>/dev/null; return 0; }
  if grep -qxF -e "$HOST_ENTRY" -e "$HOST_ENTRY_V6" "$root/etc/hosts" 2>/dev/null; then
    # Read-only rootfs (e.g. C4 on webOS 10.3.1) can't hold our entry anyway; don't let die abort Stop.
    ( unpatch_hosts_helper "$root/etc/hosts" ) >/dev/null && log "Unpatched rootfs hosts"
  fi
  umount "$root" 2>/dev/null
  rmdir "$root" 2>/dev/null
}

patch_hosts_helper() {
  f="$1"
  d="$(dirname "$f")"

  mkdir -p "$d" || die "mkdir failed: $d"
  [ -f "$f" ] || : >"$f" || die "create failed: $f"

  awk -v line="$HOST_ENTRY" '
    $0 == line { found=1 }
    END { exit (found ? 0 : 1) }
  ' "$f" || printf '\n%s\n' "$HOST_ENTRY" >>"$f"

  awk -v line="$HOST_ENTRY_V6" '
    $0 == line { found=1 }
    END { exit (found ? 0 : 1) }
  ' "$f" || printf '\n%s\n' "$HOST_ENTRY_V6" >>"$f"
}

unpatch_hosts_helper() {
  f="$1"
  [ -f "$f" ] || die "hosts missing: $f"

  tmp="/tmp/hosts.tmp.$$"
  awk -v l4="$HOST_ENTRY" -v l6="$HOST_ENTRY_V6" '$0 != l4 && $0 != l6 { print }' "$f" >"$tmp" || die "write tmp failed: $tmp"
  cat "$tmp" > "$f" || { rm -f "$tmp"; die "replace failed: $f"; }
  rm -f "$tmp"
}

manifest_field() {
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
}

# Another hosts manager (e.g. an ad blackhole tool) can rewrite these files and drop our entry.
hosts_patched() {
  grep -qxF "$HOST_ENTRY" "$HOSTS_SYSTEM" 2>/dev/null && grep -qxF "$HOST_ENTRY" "$HOSTS_JAIL" 2>/dev/null
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
  patch_cert_pin
  patch_hosts
  warn_hosts_conflicts && toast "AmazOff: blocked by another hosts entry, see Details"
  log "Successfully patched"
}

do_patch_lovefilm() {
  require_root
  log "patching target=$TARGET_DIR"
  patch_cert_pin
  patch_lovefilm_conf
  patch_lovefilm_chunk
  log "Successfully patched"
}

do_unpatch_lovefilm() {
  require_root
  log "unpatch started: target=$TARGET_DIR"
  rm -f "$TARGET_CERT_DIR_LOVEFILM/$CERT_NAME" 2>/dev/null || true
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
  log "removed Cert pinning"
  unpatch_hosts
  if [ -f "$TARGET_DIR/default_config.json.bak" ]; then
    # AmazOff <= 0.2.5 wrote disable-ssl-cert (turns off TLS checks app-wide); a .bak taken after that keeps it.
    grep -q '"disable-ssl-cert"' "$TARGET_DIR/default_config.json.bak" ||
      cat "$TARGET_DIR/default_config.json.bak" > "$TARGET_DIR/default_config.json"
    rm -f "$TARGET_DIR/default_config.json.bak" 2>/dev/null || true
    log "restored default_config"
  fi
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
  if [ -f "$CERT_DIR/$CERT_NAME" ]; then
    log "CA in place"
  else
    log "CA not found"
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

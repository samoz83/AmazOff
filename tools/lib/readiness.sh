#!/bin/sh
. "$SCRIPTS_DIR/patch.sh"
. "$SCRIPTS_DIR/netshim.sh"
. "$SCRIPTS_DIR/monitor.sh"

amazoff_ready() {
  AMAZOFF_READY_ERROR=""
  if [ "$TARGET_APP_NAME" = lovefilm ]; then
    is_lovefilm_patched && return 0
    AMAZOFF_READY_ERROR="Lovefilm patch does not match"
    return 1
  fi
  monitor_running || { AMAZOFF_READY_ERROR="monitor not running"; return 1; }
  netshim_running || { AMAZOFF_READY_ERROR="nginx not running"; return 1; }
  hosts_patched || { AMAZOFF_READY_ERROR="incomplete IPv4/IPv6 hosts entries"; return 1; }
  cert_pinned || { AMAZOFF_READY_ERROR="CA missing or contents differ"; return 1; }
  [ -z "$(hosts_conflicts)" ] || { AMAZOFF_READY_ERROR="conflicting hosts entries"; return 1; }
  # The clock can start in 2021 before synchronization. Keep TLS/date checking
  # enabled and retain its error so a failed boot has an actionable diagnosis.
  # HEAD / cannot be mistaken for a real patched-player GET or trigger its toast.
  if AMAZOFF_READY_ERROR="$(curl --noproxy '*' --silent --show-error --fail --head \
    --connect-timeout 2 --max-time 5 \
    --cacert "$CERT_DIR/$CERT_NAME" \
    --resolve cloudfront.xp-assets.aiv-cdn.net:443:127.0.0.1 \
    https://cloudfront.xp-assets.aiv-cdn.net/ 2>&1 >/dev/null)"; then
    return 0
  fi
  AMAZOFF_READY_ERROR="HTTPS check failed: $AMAZOFF_READY_ERROR"
  return 1
}

amazoff_uptime_seconds() {
  # Wall-clock corrections must not extend the readiness deadline.
  read -r amazoff_uptime amazoff_idle </proc/uptime || return 1
  printf '%s\n' "${amazoff_uptime%%.*}"
}

amazoff_wait_ready() {
  amazoff_now="$(amazoff_uptime_seconds)" || return 1
  amazoff_deadline=$((amazoff_now + 60))
  while :; do
    amazoff_ready && return 0
    log "Waiting for readiness: $AMAZOFF_READY_ERROR"
    amazoff_now="$(amazoff_uptime_seconds)" || return 1
    [ "$amazoff_now" -lt "$amazoff_deadline" ] || {
      log "ERROR: readiness did not recover within 60 seconds"
      return 1
    }
    sleep 2 || return 1
  done
}

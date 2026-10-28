# lib/monitor.sh
MON_PID="$BASE/monitor.pid"
TRIGGER_RE='ATVUnfPlayerBundle\.js.*200.*patch=[0-9a-f]+'   # only count verified patched responses


monitor_loop() {
  LOG=$LOG_MON
  echo "$$" >"$MON_PID" 2>/dev/null || exit 1

  log "monitor running pid=$$ log=$NGINX_ACCESS_LOG re=$TRIGGER_RE"

  # Other hosts managers (e.g. Glasshouse < 0.100's bind-mounted table) replace /etc/hosts; put our entry back.
  (
    warned=""; sum=""
    while sleep 10 && pid_alive "$$" && [ -f "$MON_PID" ]; do
      hosts_patched || { ( patch_hosts ) >/dev/null; log "Re-applied hosts override"; }
      # Subshell: die would end this loop, e.g. mid app update when bin/certs is missing.
      cert_pinned || { ( patch_default_conf; patch_cert_pin ) >/dev/null 2>&1 && log "Re-applied CA pin"; }
      # awk over a big blocklist every 10s is real CPU on a TV; rescan only when hosts change.
      # Some firmware (webOS 5, CX) has no cksum; fall back to md5sum. If both fail, s stays empty and we rescan every time.
      s="$(cat "$HOSTS_SYSTEM" "$HOSTS_JAIL" 2>/dev/null | { cksum 2>/dev/null || md5sum; })" && [ "$s" = "$sum" ] && continue
      sum="$s"
      # Toast once per appearance, e.g. after a blocklist upload while running.
      c="$(hosts_conflicts)"
      if [ -n "$c" ] && [ "$c" != "$warned" ]; then
        warn_hosts_conflicts
        toast "AmazOff: blocked by another hosts entry, see Details"
      fi
      warned="$c"
    done
  ) &

  # -n 0 ignores existing lines at start.
  ( tail -n 0 -F "$NGINX_ACCESS_LOG" 2>/dev/null || tail -n 0 -f "$NGINX_ACCESS_LOG" ) |
  while IFS= read -r line; do
    if echo "$line" | grep -qE 'ATVUnfPlayerBundle\.js[^"]*" 404 '; then
      toast "AmazOff: unknown player route, see Details"
      log "Unrouted player bundle request: $line"
    fi
    echo "$line" | grep -qE "$TRIGGER_RE" || continue
    toast "AmazOff loaded"
    log "AmazOff toast triggered"
  done
}

monitor_start() {
  require_root

  p="$(read_pidfile "$MON_PID" || true)"
  if pid_alive "$p"; then
    log "monitor already running pid=$p"
    return 0
  fi
  rm -f "$MON_PID" 2>/dev/null || true

  log "starting monitor daemon"

  : > "$LOG_MON"

  daemonize "$LOG_MON" sh -c '
    . "'"$SCRIPTS_DIR/common.sh"'"
    . "'"$SCRIPTS_DIR/patch.sh"'"
    . "'"$SCRIPTS_DIR/monitor.sh"'"
    monitor_loop
  '

  # Wait briefly for pidfile creation
  i=0
  while [ ! -s "$MON_PID" ] && [ $i -lt 2 ]; do
    sleep 1
    i=$((i+1))
  done

  p="$(read_pidfile "$MON_PID" || true)"
  pid_alive "$p" && log "monitor started pid=$p" || log "Monitor start FAILED"
}

monitor_stop() {
  require_root
  p="$(read_pidfile "$MON_PID" || true)"
  if pid_alive "$p"; then
    log "stopping monitor pid=$p"
    kill -TERM "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
  fi
  rm -f "$MON_PID" 2>/dev/null || true
}


monitor_status_log() {
  log "---- MONITOR INFO ----"
  p="$(read_pidfile "$MON_PID" || true)"
  if pid_alive "$p"; then
    log "monitor: running pid=$p"
  else
    log "monitor: not running"
  fi
}


monitor_running(){
  pid_alive "$(read_pidfile "$MON_PID")"
}

#!/bin/sh
ACCESS_LOG="$LOGS_BASE_DIR/access.log"

netshim_start_nginx() {
  p="$(read_pidfile "$NGINX_PID" || true)"
  if pid_alive "$p"; then
    log "nginx already running pid=$p"
    return 0
  fi

  log "preparing network for app intercept..."
  [ -x "$NGINX_BIN" ] || die "nginx not executable: $NGINX_BIN"
  [ -f "$NGINX_CONF" ] || die "nginx.conf missing: $NGINX_CONF"
  
  rm -f "$ACCESS_LOG" "$NGINX_PID" "$NGINX_LOG" 2>/dev/null

  daemonize "$NGINX_LOG" \
  "$NGINX_BIN" -c "$NGINX_CONF" -g "pid $NGINX_PID;" -p "$BASE"

  # Wait briefly for pidfile creation
  i=0
  while [ ! -s "$NGINX_PID" ] && [ $i -lt 2 ]; do
    sleep 1
    i=$((i+1))
  done

  p="$(read_pidfile "$NGINX_PID" || true)"
  pid_alive "$p" && log "NGINX started pid=$p" || log "NGINX start FAILED"
}

netshim_stop_nginx() {
  if [ -f "$NGINX_PID" ]; then
    log "stopping nginx pid=$(cat "$NGINX_PID")"
    kill "$(cat "$NGINX_PID")" 2>/dev/null
    rm -f -- "$NGINX_PID"
  fi
}

netshim_status_log() {
  p="$(read_pidfile "$NGINX_PID" || true)"
  log ""
  log "---- NET INFO ----"
  if pid_alive "$p"; then
    log "NGINX: running pid=$p"
    log "access log: 
$(cat $ACCESS_LOG)"
  else
      log "NGINX: not running"
  fi
}

netshim_running() {
  pid_alive "$(read_pidfile "$NGINX_PID")"
}
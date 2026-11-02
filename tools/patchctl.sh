#!/bin/sh
DIR="$(dirname "$0")"
. "$DIR/lib/common.sh"
. "$DIR/lib/netshim.sh"
. "$DIR/lib/patch.sh"
. "$DIR/lib/monitor.sh"

require_root
RESULT=0

SERVICESTATE="unknown"
setServiceState(){
  if [ "$TARGET_APP_NAME" = "$APP_NAME_LOVEFILM" ]; then
    if is_lovefilm_patched; then
      SERVICESTATE="running"
    elif [ "${1:-}" = "start" ]; then
      SERVICESTATE="error"
    else
      SERVICESTATE="stopped"
    fi
  else
    if monitor_running && netshim_running && hosts_patched && cert_pinned; then
      SERVICESTATE="running"
    elif [ "${1:-}" = "start" ]; then
      SERVICESTATE="error"
    else
      SERVICESTATE="stopped"
    fi
  fi
}

AUTOSTART_ENABLED="false"
setAutostartState(){
if [ -f "/var/lib/webosbrew/init.d/$AUTOSTART_ENTRY" ]; then
  AUTOSTART_ENABLED="true"
else
  AUTOSTART_ENABLED="false"
fi
}

printState(){
  echo -n "{\"state\":{\"autostart\":${AUTOSTART_ENABLED:-},\"logs\":\"$(base64 < "$LOG" | tr -d '\n')\", \"service\":\"$SERVICESTATE\"}}"
}

case "$1" in
  start)
    : > "$LOG"
    if [ "$TARGET_APP_NAME" = "$APP_NAME_LOVEFILM" ]; then
      do_patch_lovefilm
    else
      log "starting network inject"
      # Subshell: a die here must still reach the rollback below, and stdout must stay one line of JSON.
      if ! ( do_patch && netshim_start_nginx && monitor_start ) >/dev/null; then
        RESULT=1
        log "ERROR: patch preparation failed"
      fi
      if monitor_running && netshim_running && hosts_patched && cert_pinned; then
        log "Start successful"
      else
        log "Start failed"
        RESULT=1
      fi
    fi
    ;;
  stop)
    : > "$LOG"
    if [ "$TARGET_APP_NAME" = "$APP_NAME_LOVEFILM" ]; then
      do_unpatch_lovefilm
    else
      log "stopping network inject"
      # Subshell: a die must not print after the JSON or skip the state check.
      if ( monitor_stop; netshim_stop_nginx; do_unpatch ) >/dev/null; then
        log "Stop successful"
      else
        RESULT=1
        log "ERROR: Stop cleanup incomplete"
      fi
    fi
    ;;
  patch)
    : > "$LOG"
    #broken on lovefilm
    log "starting patch routine"
    ( do_patch ) >/dev/null || RESULT=1
    ;;
  unpatch)
    : > "$LOG"
    #broken on lovefilm
    log "starting unpatch routine"
    ( do_unpatch ) >/dev/null || RESULT=1
    ;;
  status)
    : > "$LOG"
    monitor_status_log
    netshim_status_log
    patch_status_log
    ;;
  autostart_toggle)
    : > "$LOG"
    setAutostartState
    if [ "${AUTOSTART_ENABLED:-}" = "true" ]; then
      rm -rf "/var/lib/webosbrew/init.d/$AUTOSTART_ENTRY" >>"$LOG" 2>&1 && log "Removed Autostart"
    else
      mkdir -p /var/lib/webosbrew/init.d && ln -sf "$AUTOSTART_SCRIPT" "/var/lib/webosbrew/init.d/$AUTOSTART_ENTRY" >>"$LOG" 2>&1 && log "Set Autostart"
    fi
    ;;
  *)
    echo "usage: patchctl.sh start|stop|patch|unpatch|status" >> "$LOG"
    exit 1
    ;;
esac
setServiceState "${1:-}"
setAutostartState
printState
if [ "$SERVICESTATE" = "error" ];then
  RESULT=1
  if [ "$TARGET_APP_NAME" = "$APP_NAME_LOVEFILM" ]; then
    do_unpatch_lovefilm
  else
    #recover partial start; subshell so a die can't print after the JSON
    ( monitor_stop; netshim_stop_nginx; do_unpatch ) >/dev/null
  fi
fi
exit "$RESULT"

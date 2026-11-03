#!/bin/sh

# Log the boot run here, including a die in common.sh, because every patchctl.sh command clears
# patcher.log. Status shows this file. The path is $BASE from common.sh.
mkdir -p /tmp/patcher && exec >/tmp/patcher/autostart.log 2>&1
date

DIR="$(dirname "$(readlink -f $0)")"
echo $DIR
. "$DIR/lib/common.sh"
. "$DIR/lib/monitor.sh"

# Not echoed: its JSON line repeats the log below in base64.
state="$($DIR/patchctl.sh start)"
echo
cat "$LOG"

# Nothing is patched after a failed Start, so leave Prime alone.
case "$state" in *'"service":"running"'*) ;; *) exit 0 ;; esac

# An app opened before Start finished keeps the unpatched player until it restarts.
# If Prime already got the patched player from nginx during Start, leave it open.
AM=luna://com.webos.applicationManager
if ! grep -qE "$TRIGGER_RE" "$NGINX_ACCESS_LOG" 2>/dev/null &&
  luna-send -n 1 "$AM/running" '{}' | grep -q "\"id\": *\"$TARGET_APP_NAME\""; then
  if luna-send -n 1 "$AM/getForegroundAppInfo" '{}' | grep -q "\"appId\": *\"$TARGET_APP_NAME\""; then
    toast "AmazOff ready, restart Prime Video to remove ads"
  else
    luna-send -n 1 "$AM/closeByAppId" "{\"id\":\"$TARGET_APP_NAME\"}" >/dev/null 2>&1
  fi
fi

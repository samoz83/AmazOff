#!/bin/sh

# Log the boot run here, including a die in common.sh, because every patchctl.sh command clears
# patcher.log. Status shows this file. The path is $BASE from common.sh.
mkdir -p /tmp/patcher && exec >/tmp/patcher/autostart.log 2>&1
date

DIR="$(dirname "$(readlink -f $0)")"
echo $DIR
. "$DIR/lib/common.sh"

$DIR/patchctl.sh start
echo
cat "$LOG"

# An app opened before Start finished keeps the unpatched player until it restarts.
AM=luna://com.webos.applicationManager
if luna-send -n 1 "$AM/running" '{}' | grep -q "\"id\": *\"$TARGET_APP_NAME\""; then
  if luna-send -n 1 "$AM/getForegroundAppInfo" '{}' | grep -q "\"appId\": *\"$TARGET_APP_NAME\""; then
    toast "AmazOff ready, restart Prime Video to remove ads"
  else
    luna-send -n 1 "$AM/closeByAppId" "{\"id\":\"$TARGET_APP_NAME\"}" >/dev/null 2>&1
  fi
fi

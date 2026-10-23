#!/bin/sh

DIR="$(dirname "$(readlink -f $0)")"
echo $DIR
. "$DIR/lib/common.sh"

$DIR/patchctl.sh start

# An app opened before Start finished keeps the unpatched player until it restarts.
AM=luna://com.webos.applicationManager
if luna-send -n 1 "$AM/running" '{}' | grep -q "\"id\": *\"$TARGET_APP_NAME\""; then
  if luna-send -n 1 "$AM/getForegroundAppInfo" '{}' | grep -q "\"appId\": *\"$TARGET_APP_NAME\""; then
    toast "AmazOff ready, restart Prime Video to remove ads"
  else
    luna-send -n 1 "$AM/closeByAppId" "{\"id\":\"$TARGET_APP_NAME\"}" >/dev/null 2>&1
  fi
fi

#!/bin/sh
# Older webOS BusyBox uses -t; newer BusyBox/coreutils take positional seconds.
seconds="$1"
shift
case "$seconds" in ''|*[!0-9]*) exit 2 ;; esac
if timeout --help 2>&1 | grep -q '\[-t SECS\]'; then
  exec timeout -t "$seconds" "$@"
else
  exec timeout "$seconds" "$@"
fi

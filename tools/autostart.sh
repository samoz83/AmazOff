#!/bin/sh

DIR="$(dirname "$(readlink -f "$0")")"
# Bound the whole worker, including Start and filesystem/service delays.
if [ "${1:-}" != "--worker" ]; then
  exec sh "$DIR/timeout.sh" 100 sh "$DIR/autostart.sh" --worker
fi
. "$DIR/lib/common.sh"
require_root
. "$DIR/lib/readiness.sh"
umask 077
LOG="$BASE/boot.log"

# mkdir supplies an atomic lock without adding a flock dependency on older TVs.
mkdir "$BASE/boot.lock.d" 2>/dev/null || exit 0
trap 'rmdir "$BASE/boot.lock.d" 2>/dev/null' 0
trap 'exit 1' 1 2 15
[ ! -f "$BASE/boot.complete" ] || exit 0
log "Boot integration starting"
if ! sh "$DIR/timeout.sh" 25 "$DIR/patchctl.sh" start >>"$LOG" 2>&1; then
  log "ERROR: Start failed; Prime left untouched"
  exit 1
fi
if ! amazoff_wait_ready; then
  log "ERROR: readiness failed; Prime left untouched"
  exit 1
fi

# Prime can already have fetched the patch during Start. Readiness alone cannot
# establish which player an existing process has loaded, so never close it.
log "AmazOff ready; Prime left untouched"
: >"$BASE/boot.complete"
log "Boot integration complete"

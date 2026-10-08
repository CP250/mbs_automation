#!/bin/bash
# mount_garm_assets.sh - keep hoest's link to garm's asset share mounted.
#
# WHY (found 2026-10-08, P's VPN test): ~/storage_mbs_assets on hoest is a symlink
# to /Volumes/storage_mbs_assets, the SMB share garm serves. Over the iPhone
# hotspot plus Teleport the share works, but when the network changes macOS drops
# the mount and does not bring it back, so the link points at nothing and every
# file:// link into the asset mirror breaks until someone reconnects by hand.
#
# WHAT: fire-and-exit, every 60 seconds (com.mbs.mount-garm-assets, hoest only,
# RunAtLoad). It does nothing unless BOTH are true: the share is not mounted, and
# garm's SMB port (445) answers. "Not reachable" is normal (laptop away without a
# tunnel) and is silent. When it does act it uses the same call that was proven by
# hand: osascript "mount volume", which authenticates with the shared Apple
# Account and shows no dialog.
#
# GUARDS, deliberately:
#   - never forces or unmounts anything. A share that is listed as mounted but does
#     not answer ls within LS_TIMEOUT seconds is reported (FAILED, rate limited) and
#     left alone.
#   - after a FAILED attempt it will not try again for 10 minutes. A rejected login
#     can raise a password dialog on the screen; once per minute would be a nuisance.
#   - a healthy minute writes nothing, so the log grows only on events. Terminal
#     lines use the estate vocabulary (completed successfully / FAILED) so heartbeat
#     check 26 can read them.
#   - always exits 0: a non-zero exit would mark the launchd job as failing for a
#     condition (garm unreachable) that is not a fault.
#
# Must stay compatible with macOS /bin/bash 3.2. Commands are overridable through
# the *_BIN variables so scripts/mount_garm_assets_drill.sh can run it with shims.

set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

HOST="${GARM_ASSETS_HOST:-192.168.1.205}"
SHARE="${GARM_ASSETS_SHARE:-storage_mbs_assets}"
MOUNTPOINT="${GARM_ASSETS_MOUNTPOINT:-/Volumes/$SHARE}"
LS_TIMEOUT="${GARM_ASSETS_LS_TIMEOUT:-8}"
MOUNT_TIMEOUT="${GARM_ASSETS_MOUNT_TIMEOUT:-45}"
RETRY_SECONDS="${GARM_ASSETS_RETRY_SECONDS:-600}"

NC_BIN="${NC_BIN:-/usr/bin/nc}"
OSA_BIN="${OSA_BIN:-/usr/bin/osascript}"
MOUNT_BIN="${MOUNT_BIN:-/sbin/mount}"
LS_BIN="${LS_BIN:-/bin/ls}"
PERL_BIN="${PERL_BIN:-/usr/bin/perl}"

STATE_DIR="$HOME/.mbs_automation"
LOG="$STATE_DIR/mount_garm_assets.log"
FAIL_STAMP="$STATE_DIR/.mount_garm_assets_last_failed"
mkdir -p "$STATE_DIR"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Run a command with a time limit WITHOUT dying by signal. A plain perl alarm kills
# the command with SIGALRM and bash then prints "Alarm clock: 14" to stderr, which
# lands in the job's error log and trips heartbeat check 24 (any job wrote to
# stderr). Here perl forks the command, kills it at the limit and exits 124, an
# ordinary exit status, so nothing is printed.
with_timeout() {
  local secs="$1"; shift
  "$PERL_BIN" -e '$s = shift; $pid = fork(); if (!$pid) { exec @ARGV; exit 127 } $SIG{ALRM} = sub { kill 9, $pid; exit 124 }; alarm $s; waitpid($pid, 0); exit($? >> 8)' "$secs" "$@"
}

# True when the last FAILED attempt or report was less than RETRY_SECONDS ago.
recently_failed() {
  local last now
  last="$(cat "$FAIL_STAMP" 2>/dev/null)"
  case "$last" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  [ $(( now - last )) -lt "$RETRY_SECONDS" ]
}
note_failed() { date +%s > "$FAIL_STAMP"; }

is_mounted() { "$MOUNT_BIN" 2>/dev/null | grep -q " on ${MOUNTPOINT} "; }

if is_mounted; then
  if with_timeout "$LS_TIMEOUT" "$LS_BIN" "$MOUNTPOINT" >/dev/null 2>&1; then
    exit 0
  fi
  if ! recently_failed; then
    echo "$(ts) - FAILED: ${MOUNTPOINT} is mounted but did not answer within ${LS_TIMEOUT}s (stale mount); left alone, not forced" >> "$LOG"
    note_failed
  fi
  exit 0
fi

# Not mounted. Silent when garm cannot be reached: that is the normal state away
# from home without a tunnel.
"$NC_BIN" -z -w 3 "$HOST" 445 >/dev/null 2>&1 || exit 0

# Reachable but not mounted. Respect the pause after a failed attempt.
recently_failed && exit 0

OUT="$(with_timeout "$MOUNT_TIMEOUT" "$OSA_BIN" -e "mount volume \"smb://${HOST}/${SHARE}\"" 2>&1)"
if is_mounted; then
  echo "$(ts) - mounted smb://${HOST}/${SHARE} at ${MOUNTPOINT}" >> "$LOG"
  echo "$(ts) - completed successfully" >> "$LOG"
  rm -f "$FAIL_STAMP"
else
  FIRST="$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-140)"
  echo "$(ts) - FAILED: could not mount smb://${HOST}/${SHARE}; next attempt in $(( RETRY_SECONDS / 60 )) minutes. ${FIRST}" >> "$LOG"
  note_failed
fi
exit 0

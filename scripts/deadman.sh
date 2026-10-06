#!/bin/bash
# deadman.sh - the garm dead-man check-in sender (com.mbs.deadman).
#
# Fires every 15 minutes (StartInterval 900). Two independent check-ins, so an
# outage of either off-box receiver cannot hide the other:
#   A  POST to the Home Assistant webhook on Svartulv (http://10.99.0.1:8123/api/webhook/<id>).
#      The id is a secret held in the login Keychain item mbs-deadman-ha-webhook.
#      HA pushes to P's phone after 30 minutes without a check-in and on recovery.
#   B  CloudWatch PutMetricData, namespace MBS/Garm, metric DeadmanCheckin, value 1,
#      dimension Host=<this host>, account mbs-automation, us-east-1, AWS profile
#      mbs-deadman (a credential that can only call PutMetricData in that namespace).
#      The alarm fires on 2 consecutive 15-minute periods of missing data and emails
#      through mbs-alerts.
#
# Contract: handoff_garm_agents.md, shared rule 6. This job is deliberately NOT
# part of mbs_heartbeat.sh, which stays network-free. One attempt per side per
# run, never a retry loop: the next trigger is the retry, and silence is the
# signal the receivers are built to detect.
#
# The webhook id and the URL built from it never reach the log, the process list
# (curl reads its URL from stdin) or stdout.
#
# Logs one terminal line per run in the estate vocabulary, so heartbeat check 26
# reads it: "completed successfully" or "FAILED: <which side>".
#
# Test hooks (env): STATE_DIR, DEADMAN_SECURITY, DEADMAN_CURL, DEADMAN_AWS,
# DEADMAN_HA_BASE, DEADMAN_HOST, MBS_KEYCHAIN_TIMEOUT_S.

set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

STATE_DIR="${STATE_DIR:-$HOME/.mbs_automation}"
LOG="$STATE_DIR/deadman.log"
STAMP="$STATE_DIR/last_deadman_run"
KEYCHAIN_ITEM="mbs-deadman-ha-webhook"
SECURITY_BIN="${DEADMAN_SECURITY:-/usr/bin/security}"
CURL_BIN="${DEADMAN_CURL:-curl}"
AWS_BIN="${DEADMAN_AWS:-aws}"
HA_BASE="${DEADMAN_HA_BASE:-http://10.99.0.1:8123/api/webhook/}"
HOST_DIM="${DEADMAN_HOST:-$(hostname -s)}"
KEYCHAIN_TIMEOUT_S="${MBS_KEYCHAIN_TIMEOUT_S:-20}"

mkdir -p "$STATE_DIR"
ts() { TZ=America/New_York date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) - $*" >> "$LOG"; }

FAILED_SIDES=""

# --- A: Home Assistant webhook ----------------------------------------------
# Bounded Keychain read (same reasoning as vault_backup.sh, 2026-09-12): an item
# whose ACL does not trust the reader raises a desktop dialog and waits forever.
# The value goes to a 600 temp file, never to the log.
KC_OUT="${TMPDIR:-/tmp}/deadman_kc_$$"
KC_STATUS="$KC_OUT.status"
rm -f "$KC_OUT" "$KC_STATUS"
( umask 077; "$SECURITY_BIN" find-generic-password -w -s "$KEYCHAIN_ITEM" > "$KC_OUT" 2>/dev/null; echo $? > "$KC_STATUS" ) &
KC_PID=$!
KC_WAITED=0
while [ ! -f "$KC_STATUS" ] && [ "$KC_WAITED" -lt "$KEYCHAIN_TIMEOUT_S" ]; do
  sleep 1
  KC_WAITED=$((KC_WAITED + 1))
done
if [ ! -f "$KC_STATUS" ]; then
  kill -TERM "$KC_PID" 2>/dev/null
  log "A FAILED: keychain item $KEYCHAIN_ITEM did not answer within ${KEYCHAIN_TIMEOUT_S}s (an authorization dialog or a locked keychain)"
  FAILED_SIDES="${FAILED_SIDES}${FAILED_SIDES:+ }A"
elif [ "$(cat "$KC_STATUS")" != "0" ] || [ ! -s "$KC_OUT" ]; then
  log "A FAILED: could not read keychain item $KEYCHAIN_ITEM (status $(cat "$KC_STATUS"))"
  FAILED_SIDES="${FAILED_SIDES}${FAILED_SIDES:+ }A"
else
  WEBHOOK_ID="$(tr -d '[:space:]' < "$KC_OUT")"
  if printf 'url = "%s%s"\n' "$HA_BASE" "$WEBHOOK_ID" | "$CURL_BIN" -sS --fail -m 15 -X POST -o /dev/null -K - 2>"$KC_OUT.err"; then
    log "A ok: Home Assistant webhook accepted the check-in"
  else
    log "A FAILED: Home Assistant webhook did not accept the check-in: $(tr -d '\n' < "$KC_OUT.err" | cut -c1-160)"
    FAILED_SIDES="${FAILED_SIDES}${FAILED_SIDES:+ }A"
  fi
  unset WEBHOOK_ID
fi
rm -f "$KC_OUT" "$KC_STATUS" "$KC_OUT.err"

# --- B: CloudWatch -----------------------------------------------------------
if AWS_PAGER="" "$AWS_BIN" cloudwatch put-metric-data --profile mbs-deadman --region us-east-1 \
     --cli-connect-timeout 15 --cli-read-timeout 30 \
     --namespace MBS/Garm --metric-name DeadmanCheckin --value 1 --unit Count \
     --dimensions "Host=$HOST_DIM" >/dev/null 2>"$STATE_DIR/deadman.aws.err"; then
  log "B ok: CloudWatch accepted DeadmanCheckin for Host=$HOST_DIM"
else
  log "B FAILED: CloudWatch PutMetricData failed: $(tr -d '\n' < "$STATE_DIR/deadman.aws.err" | cut -c1-160)"
  FAILED_SIDES="${FAILED_SIDES}${FAILED_SIDES:+ }B"
fi
rm -f "$STATE_DIR/deadman.aws.err"

if [ -n "$FAILED_SIDES" ]; then
  log "FAILED: dead-man check-in side(s) failed: $FAILED_SIDES"
  exit 1
fi
date +%s > "$STAMP"
log "completed successfully"
exit 0

#!/bin/bash
# garm_unlock.sh: bring garm (the New Canaan Mac mini) back after a power loss.
#
# Run from the MacBook. Works on the home LAN or through either remote path
# (the UDM Pro WireGuard VPN Server or UniFi Teleport), because both route
# 192.168.1.0/24. Tailscale running on garm could not help here: it does not
# start until the FileVault disk is unlocked.
#
# What it does, in order:
#   1. Checks garm answers on TCP 22 at its reserved IP. Not garm.local:
#      Bonjour names may not resolve before the disk is unlocked.
#   2. Works out garm's state: FileVault pre-boot, booted at the login
#      window, or booted and logged in.
#   3. Pre-boot: opens a password-only SSH session and P types the FileVault
#      password at the prompt. The password is never stored or read by this
#      script; it is memorized-only (ref_digital_security_architecture).
#   4. Waits for normal macOS to accept garm's SSH key.
#   5. Login window: opens Screen Sharing and P logs in. The LaunchAgents,
#      Obsidian and the login keychain all need that GUI session.
#   6. Verifies the GUI session and reports what is loaded, with timings.
#
# How pre-boot is recognised (revised 2026-10-04 after the first live run):
# the pre-boot server may advertise publickey even though it cannot read
# authorized_keys while the disk is locked, so "key refused" alone is
# ambiguous. --enroll therefore proves key login once and records the key's
# fingerprint. Afterwards, a refusal of that same verified key is read as
# "garm is locked" and the script offers to unlock. A refusal of a key that
# was never verified is reported as a key problem.
#
# Observed live on garm 2026-10-04 (macOS 26): the pre-boot server reports
# OpenSSH_10.3, offers publickey,password,keyboard-interactive, takes the
# account password, replies "System successfully unlocked. You may now use
# SSH to authenticate normally." and closes the connection. The unlock uses
# keyboard-interactive only: with password allowed as a fallback, ssh raced
# the closing connection and showed a second, pointless password prompt
# (first live drill, 2026-10-04). On Apple silicon
# the FileVault screen on a monitor looks like the login window.
#
# Host key: pinned in its own known_hosts file. An unknown or changed key
# stops the script before any password is asked for, so nothing pretending
# to be garm can collect the FileVault password.
#
# Usage: garm_unlock.sh [--status | --enroll | --force-unlock] [--host IP]
#   --status        report garm's state, SSH version and offered methods
#   --enroll        pin garm's host key and prove key login (garm unlocked)
#   --force-unlock  skip state detection and go straight to the unlock prompt
#   --host IP       override the address (default 192.168.1.205)
#
# Phone-only fallback (no laptop): connect Teleport or WireGuard on the
# iPhone, SSH to cpreston@192.168.1.205 with password auth and type the
# FileVault password, wait a minute, then open vnc://192.168.1.205 in a VNC
# app and log in.
#
# Must stay compatible with macOS /bin/bash 3.2.

set -u

GARM_HOST="${GARM_HOST:-192.168.1.205}"
GARM_USER="${GARM_USER:-cpreston}"
GARM_KEY="${GARM_KEY:-$HOME/.ssh/id_ed25519_garm}"
GARM_KNOWN_HOSTS="${GARM_KNOWN_HOSTS:-$HOME/.ssh/known_hosts_garm}"
GARM_KEY_MARK="${GARM_KEY_MARK:-$HOME/.ssh/garm_key_verified}"
BOOT_WAIT_S="${BOOT_WAIT_S:-360}"
RETRY_AFTER_S="${RETRY_AFTER_S:-90}"
LOGIN_WAIT_S="${LOGIN_WAIT_S:-600}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
NC_BIN="${NC_BIN:-/usr/bin/nc}"

MODE="unlock"
while [ $# -gt 0 ]; do
  case "$1" in
    --status) MODE="status" ;;
    --enroll) MODE="enroll" ;;
    --force-unlock) MODE="force" ;;
    --host) shift; GARM_HOST="${1:?--host needs an address}" ;;
    -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

START_TS=$(date +%s)
elapsed() { echo $(( $(date +%s) - START_TS )); }
say() { echo "[$(elapsed)s] $*"; }
die() { echo "[$(elapsed)s] STOP: $*" >&2; exit 1; }

SSH_BASE=(-o "UserKnownHostsFile=$GARM_KNOWN_HOSTS" -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -o LogLevel=ERROR)
SSH_KEY=(-o BatchMode=yes -o IdentitiesOnly=yes -i "$GARM_KEY" -o PreferredAuthentications=publickey)
SSH_NOAUTH=(-o BatchMode=yes -o PubkeyAuthentication=no -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no)

port_open() {
  "$NC_BIN" -z -G 5 "$GARM_HOST" 22 >/dev/null 2>&1
}

# Connects with every client auth method disabled and prints the verbose
# transcript, which carries the server version and the offered methods.
probe() {
  ssh -v -o "UserKnownHostsFile=$GARM_KNOWN_HOSTS" -o StrictHostKeyChecking=yes \
      -o ConnectTimeout=8 "${SSH_NOAUTH[@]}" "$GARM_USER@$GARM_HOST" true 2>&1
}

# Prints HOSTKEY on a host key problem, else the comma-separated list of
# methods the server offers (empty if it could not be read).
auth_methods() {
  local out
  out=$(ssh "${SSH_BASE[@]}" "${SSH_NOAUTH[@]}" "$GARM_USER@$GARM_HOST" true 2>&1)
  case "$out" in
    *"Host key verification failed"*|*"IDENTIFICATION HAS CHANGED"*|*"host key is known"*)
      echo "HOSTKEY"; return ;;
  esac
  echo "$out" | sed -n 's/.*Permission denied (\(.*\))\..*/\1/p' | head -1
}

key_ok() {
  ssh "${SSH_BASE[@]}" "${SSH_KEY[@]}" "$GARM_USER@$GARM_HOST" true >/dev/null 2>&1
}

on_garm() {
  ssh "${SSH_BASE[@]}" "${SSH_KEY[@]}" "$GARM_USER@$GARM_HOST" "$@"
}

console_user() {
  on_garm 'stat -f %Su /dev/console' 2>/dev/null
}

key_fp() {
  ssh-keygen -lf "$GARM_KEY" 2>/dev/null | awk '{print $2}'
}

mark_key_verified() {
  local fp
  fp=$(key_fp)
  [ -n "$fp" ] || return 0
  echo "$(date '+%Y-%m-%d %H:%M') $fp" > "$GARM_KEY_MARK" && chmod 600 "$GARM_KEY_MARK"
}

key_verified() {
  local fp
  fp=$(key_fp)
  [ -n "$fp" ] && [ -f "$GARM_KEY_MARK" ] && grep -qF "$fp" "$GARM_KEY_MARK"
}

# OFFLINE | HOSTKEY | LOGGEDIN | LOGINWINDOW | PREBOOT | LOCKED_LIKELY |
# KEYREFUSED | UNKNOWN
detect_state() {
  local m u
  if ! port_open; then echo "OFFLINE"; return; fi
  m=$(auth_methods)
  if [ "$m" = "HOSTKEY" ]; then echo "HOSTKEY"; return; fi
  if key_ok; then
    mark_key_verified
    u=$(console_user)
    if [ "$u" = "$GARM_USER" ]; then echo "LOGGEDIN"; else echo "LOGINWINDOW"; fi
    return
  fi
  case ",$m," in
    ,,) echo "UNKNOWN" ;;
    *,publickey,*)
      if key_verified; then echo "LOCKED_LIKELY"; else echo "KEYREFUSED"; fi ;;
    *) echo "PREBOOT" ;;
  esac
}

is_locked_state() {
  [ "$1" = "PREBOOT" ] || [ "$1" = "LOCKED_LIKELY" ]
}

explain_and_stop() {
  case "$1" in
    OFFLINE)
      die "garm does not answer on $GARM_HOST:22. One of: power is not back yet or garm did not auto-start; New Canaan's internet is down (the modem is not on the UPS); or your tunnel is not up. Connect Teleport (WiFiman) or the WireGuard tunnel and retry." ;;
    HOSTKEY)
      die "garm's host key does not match the pinned key. Do NOT type your password anywhere. If garm was reinstalled, re-run --enroll from home; otherwise something else is answering at $GARM_HOST." ;;
    KEYREFUSED)
      die "garm refused $GARM_KEY, and this key has never been proven against garm. If garm's screen shows a password field it may be locked: use --force-unlock. Otherwise install the key from home (ssh-copy-id -i $GARM_KEY.pub $GARM_USER@$GARM_HOST) and run --enroll while garm is unlocked." ;;
    UNKNOWN)
      die "could not tell garm's state. Retry in a minute, or use --force-unlock if you know it is at the FileVault screen." ;;
  esac
}

enroll() {
  local tmp ans fp
  port_open || die "garm does not answer on $GARM_HOST:22. Enroll from the home network."
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  tmp=$(mktemp)
  ssh-keyscan -T 8 -t ed25519 "$GARM_HOST" 2>/dev/null > "$tmp"
  [ -s "$tmp" ] || { rm -f "$tmp"; die "garm returned no ed25519 host key."; }
  fp=$(ssh-keygen -lf "$tmp" | awk '{print $2}')
  if [ -f "$GARM_KNOWN_HOSTS" ] && ssh-keygen -l -F "$GARM_HOST" -f "$GARM_KNOWN_HOSTS" 2>/dev/null | grep -qF "$fp"; then
    say "Host key already pinned ($fp)."
  else
    echo "garm presents this host key:"
    ssh-keygen -lf "$tmp"
    echo
    echo "Compare it with what garm reports about itself. In an SSH session on garm run:"
    echo "  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
    printf "Do the two SHA256 fingerprints match? [y/N] "
    read -r ans
    case "$ans" in
      y|Y|yes|YES)
        if [ -f "$GARM_KNOWN_HOSTS" ]; then ssh-keygen -R "$GARM_HOST" -f "$GARM_KNOWN_HOSTS" >/dev/null 2>&1; fi
        cat "$tmp" >> "$GARM_KNOWN_HOSTS"
        chmod 600 "$GARM_KNOWN_HOSTS"
        rm -f "$GARM_KNOWN_HOSTS.old"
        say "Pinned garm's host key in $GARM_KNOWN_HOSTS." ;;
      *)
        rm -f "$tmp"
        die "Not pinned." ;;
    esac
  fi
  rm -f "$tmp"
  [ -f "$GARM_KEY" ] || die "no SSH key at $GARM_KEY. Create it: ssh-keygen -t ed25519 -f $GARM_KEY -C hoest-to-garm -N \"\""
  if key_ok; then
    mark_key_verified
    say "Key login verified; recorded in $GARM_KEY_MARK. From now on a refusal of this key means garm is locked."
  else
    rm -f "$GARM_KEY_MARK"
    die "Key login failed. With garm unlocked (login window or desktop), run: ssh-copy-id -i $GARM_KEY.pub $GARM_USER@$GARM_HOST   then --enroll again."
  fi
}

status() {
  local state out ver meth
  state=$(detect_state)
  out=$(probe | tr -d '\r')
  ver=$(echo "$out" | sed -n 's/.*remote software version \(.*\)$/\1/p' | head -1)
  meth=$(echo "$out" | sed -n 's/.*Authentications that can continue: \(.*\)$/\1/p' | head -1)
  say "garm state: $state"
  say "server: ${ver:-unknown}; offers: ${meth:-unknown}"
  if key_verified; then say "key: verified ($(cat "$GARM_KEY_MARK"))"; else say "key: never verified, run --enroll"; fi
}

# Runs the password-only session, then waits for normal macOS. Offers a retry
# if garm still looks locked RETRY_AFTER_S seconds later (wrong password).
unlock_and_wait() {
  local attempt=1 t0 waited ans out rejected
  out=$(mktemp)
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    say "Unlock attempt $attempt of $MAX_ATTEMPTS. Type the FileVault password at the prompt."
    say "The connection drops when the disk unlocks; that is expected."
    rejected=0
    ssh "${SSH_BASE[@]}" -o PubkeyAuthentication=no \
        -o PreferredAuthentications=keyboard-interactive \
        -o NumberOfPasswordPrompts=1 "$GARM_USER@$GARM_HOST" true 2>&1 | tee "$out"
    if grep -q "System successfully unlocked" "$out"; then
      say "garm confirmed the disk is unlocked."
      if grep -q "Permission denied" "$out"; then
        say "(The \"Permission denied\" line above is ssh closing out after the unlock. It is expected; ignore it.)"
      fi
    elif grep -q "Permission denied" "$out"; then
      say "garm rejected the password."
      rejected=1
    fi
    if [ "$rejected" -eq 0 ]; then
      say "Waiting for macOS to finish booting (up to ${BOOT_WAIT_S}s)."
      t0=$(date +%s)
      while :; do
        waited=$(( $(date +%s) - t0 ))
        if key_ok; then
          mark_key_verified
          rm -f "$out"
          say "macOS accepted the key ${waited}s after the unlock session closed."
          return 0
        fi
        if [ "$waited" -ge "$RETRY_AFTER_S" ] && is_locked_state "$(detect_state)"; then
          say "garm still looks locked after ${waited}s, so the unlock did not take."
          break
        fi
        if [ "$waited" -ge "$BOOT_WAIT_S" ]; then
          rm -f "$out"
          die "macOS did not come up within ${BOOT_WAIT_S}s. Check the tunnel, then run --status."
        fi
        sleep 5
      done
    fi
    attempt=$(( attempt + 1 ))
    [ "$attempt" -le "$MAX_ATTEMPTS" ] || break
    printf "Try again? [y/N] "
    read -r ans
    case "$ans" in y|Y|yes|YES) ;; *) rm -f "$out"; die "Stopped with garm locked." ;; esac
  done
  rm -f "$out"
  die "Unlock failed after $MAX_ATTEMPTS attempts."
}

login_via_screen_sharing() {
  local t0
  [ "$(console_user)" = "$GARM_USER" ] && return 0
  say "garm is at the login window. Opening Screen Sharing: log in as $GARM_USER."
  open "vnc://$GARM_USER@$GARM_HOST"
  t0=$(date +%s)
  while [ "$(console_user)" != "$GARM_USER" ]; do
    if [ $(( $(date +%s) - t0 )) -ge "$LOGIN_WAIT_S" ]; then
      die "No login seen within ${LOGIN_WAIT_S}s. Log in through Screen Sharing, then run --status."
    fi
    sleep 5
  done
  say "Logged in ($(( $(date +%s) - t0 ))s at the login window)."
}

verify() {
  local uid jobs obs
  uid=$(on_garm 'id -u' 2>/dev/null)
  [ -n "$uid" ] || die "could not reach garm to verify."
  jobs=$(on_garm "launchctl print gui/$uid 2>/dev/null | grep -oE 'com\\.mbs\\.[A-Za-z0-9._-]+' | sort -u | wc -l" 2>/dev/null | tr -d ' ')
  obs=$(on_garm 'pgrep -x Obsidian >/dev/null && echo running || echo "NOT running"' 2>/dev/null)
  say "garm is up: console user $GARM_USER, ${jobs:-?} com.mbs jobs loaded, Obsidian $obs."
  say "Done in $(elapsed)s."
}

if [ "$MODE" = "enroll" ]; then
  enroll
  exit 0
fi

[ -s "$GARM_KNOWN_HOSTS" ] || die "garm's host key is not pinned yet. From the home network run: $0 --enroll"
[ -f "$GARM_KEY" ] || die "no SSH key at $GARM_KEY. Create it with: ssh-keygen -t ed25519 -f $GARM_KEY -C hoest-to-garm -N \"\"   then: ssh-copy-id -i $GARM_KEY.pub $GARM_USER@$GARM_HOST   then: $0 --enroll"

if [ "$MODE" = "status" ]; then
  status
  exit 0
fi

if [ "$MODE" = "force" ]; then
  state="PREBOOT"
else
  state=$(detect_state)
fi

case "$state" in
  LOGGEDIN)
    say "garm is already up and logged in. Nothing to unlock."
    verify ;;
  LOGINWINDOW)
    login_via_screen_sharing
    verify ;;
  PREBOOT)
    unlock_and_wait
    login_via_screen_sharing
    verify ;;
  LOCKED_LIKELY)
    say "garm offers key login but refuses the key that worked at enrollment ($(cut -d' ' -f1-2 "$GARM_KEY_MARK")). That is how a locked garm looks from outside."
    printf "Unlock now? [Y/n] "
    read -r ans
    case "$ans" in n|N|no|NO) die "Not unlocking." ;; esac
    unlock_and_wait
    login_via_screen_sharing
    verify ;;
  *)
    explain_and_stop "$state" ;;
esac

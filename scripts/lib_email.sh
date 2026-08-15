#!/bin/bash
# lib_email.sh - sourceable SMTP send helper for mbs_automation scripts.
#
# Provides one function: send_email <to> <subject> <body_file>
#   - <to>          recipient address (string)
#   - <subject>     plain subject line (string)
#   - <body_file>   path to a UTF-8 text file containing the message body
#
# Reads SMTP credentials from a file at ~/.mbs_automation/secrets/gmail_app_password.
# The file must contain exactly the Gmail app password on a single line (16 chars
# with or without spaces - Google's app-password format). Permissioned 600 by P.
# SMTP user is fixed to chris.preston@gmail.com.
#
# Returns 0 on success, non-zero on failure. Caller decides how to surface errors.
#
# Uses Python's standard-library smtplib via the system /usr/bin/python3 so we
# don't take a Homebrew dependency. Body is sent as text/plain UTF-8.
#
# Sourcing pattern (in caller):
#   source "$(dirname "${BASH_SOURCE[0]}")/lib_email.sh"
#   send_email "chris.preston@gmail.com" "Subject" "/tmp/body.txt"

SMTP_HOST="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER="chris.preston@gmail.com"
SMTP_PASSWORD_FILE="$HOME/.mbs_automation/secrets/gmail_app_password"

send_email() {
  local to="$1"
  local subject="$2"
  local body_file="$3"

  if [ -z "$to" ] || [ -z "$subject" ] || [ -z "$body_file" ]; then
    echo "send_email: usage: send_email <to> <subject> <body_file>" >&2
    return 2
  fi

  if [ ! -f "$body_file" ]; then
    echo "send_email: body file not found: $body_file" >&2
    return 2
  fi

  if [ ! -f "$SMTP_PASSWORD_FILE" ]; then
    echo "send_email: SMTP password file missing: $SMTP_PASSWORD_FILE" >&2
    echo "send_email: create it (chmod 600) with the Gmail app password on one line." >&2
    return 3
  fi

  # Strip any whitespace (including the 4-group format Google shows) from the password.
  local password
  password="$(tr -d '[:space:]' < "$SMTP_PASSWORD_FILE")"
  if [ -z "$password" ]; then
    echo "send_email: SMTP password file is empty: $SMTP_PASSWORD_FILE" >&2
    return 3
  fi

  SMTP_HOST="$SMTP_HOST" \
  SMTP_PORT="$SMTP_PORT" \
  SMTP_USER="$SMTP_USER" \
  SMTP_PASSWORD="$password" \
  EMAIL_TO="$to" \
  EMAIL_SUBJECT="$subject" \
  EMAIL_BODY_FILE="$body_file" \
  /usr/bin/python3 - <<'PYEOF'
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage

host = os.environ["SMTP_HOST"]
port = int(os.environ["SMTP_PORT"])
user = os.environ["SMTP_USER"]
password = os.environ["SMTP_PASSWORD"]
to = os.environ["EMAIL_TO"]
subject = os.environ["EMAIL_SUBJECT"]
body_file = os.environ["EMAIL_BODY_FILE"]

with open(body_file, "r", encoding="utf-8") as f:
    body = f.read()

msg = EmailMessage()
msg["From"] = user
msg["To"] = to
msg["Subject"] = subject
msg.set_content(body)

try:
    context = ssl.create_default_context()
    with smtplib.SMTP(host, port, timeout=30) as server:
        server.ehlo()
        server.starttls(context=context)
        server.ehlo()
        server.login(user, password)
        server.send_message(msg)
except Exception as e:
    sys.stderr.write(f"send_email: SMTP error: {e}\n")
    sys.exit(1)

sys.exit(0)
PYEOF
  return $?
}

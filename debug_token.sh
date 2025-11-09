#!/usr/bin/env bash
set -euo pipefail

PANEL_HOST="93.127.133.51"
PANEL_USER="administrator"
PANEL_PASS="GoldvisioN@1982"
STREAM_HOST="95.217.193.163"

if [ $# -ne 1 ]; then
  echo "Usage: ./debug_token.sh <username>"
  exit 1
fi

USERNAME="$1"

echo "=== Panel SQLite entry ==="
sshpass -p "$PANEL_PASS" ssh -o StrictHostKeyChecking=no "$PANEL_USER@$PANEL_HOST" <<'EOFREMOTE'
USERNAME_REMOTE="'$USERNAME'"
echo '$PANEL_PASS' | sudo -S ./venv/bin/python - <<'PY'
from app import app, db, User
import os
username = os.environ['USERNAME_REMOTE']
with app.app_context():
    user = User.query.filter_by(username=username).first()
    if not user:
        print('User not found in DB')
    else:
        print('username:', user.username)
        print('password:', user.password)
        print('token:', user.token)
        print('expiry:', user.expiry_date)
PY
EOFREMOTE


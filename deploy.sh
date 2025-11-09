#!/usr/bin/env bash
set -euo pipefail

# --- Config you might tweak ---
REMOTE_HOST="93.127.133.51"
REMOTE_USER="administrator"
REMOTE_PASS="GoldvisioN@1982"
REMOTE_DIR="/opt/IptvPannel"

LOCAL_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_SCRIPT="pannel.sh"
REMOTE_SSL_SCRIPT="remote_ssl_setup.sh"

# --- Installer answers ---
INSTALL_DIR_INPUT=""  # leave blank for default (/opt/iptv-panel)
STREAM_DOMAIN="stream.goalfete.com"
STREAM_IP="95.217.193.163"
ADMIN_PASSWORD="GoldvisioN@1982"
STREAMING_API_BASE=""  # leave blank to skip
STREAMING_API_TOKEN=""
STREAMING_API_TIMEOUT="10"
CLOUDFLARE_ZONE_ID=""
CLOUDFLARE_API_TOKEN=""
POSTGRES_DB="iptv_panel"
POSTGRES_USER="iptv_admin"
POSTGRES_PASSWORD=""  # leave blank to auto-generate on server
PANEL_DOMAIN="panel.goalfete.com"
CERTBOT_EMAIL="admin@goalfete.com"

REMOTE_INSTALL_DIR="${INSTALL_DIR_INPUT:-/opt/iptv-panel}"

# --- Pre-flight checks ---
command -v sshpass >/dev/null || { echo "sshpass is required"; exit 1; }
command -v rsync >/dev/null   || { echo "rsync is required"; exit 1; }
command -v ssh >/dev/null     || { echo "ssh is required"; exit 1; }

if [ ! -f "${LOCAL_PROJECT_DIR}/${INSTALL_SCRIPT}" ]; then
  echo "Cannot find ${INSTALL_SCRIPT} in ${LOCAL_PROJECT_DIR}"
  exit 1
fi

if [ ! -f "${LOCAL_PROJECT_DIR}/${REMOTE_SSL_SCRIPT}" ]; then
  echo "Cannot find ${REMOTE_SSL_SCRIPT} in ${LOCAL_PROJECT_DIR}"
  exit 1
fi

if [ -t 0 ]; then
  read -p "Installer will COMPLETELY configure the remote server (apt, postgres, nginx). Continue? [y/N]: " CONFIRM || CONFIRM="y"
  CONFIRM_LOWER=$(printf '%s' "$CONFIRM" | tr '[:upper:]' '[:lower:]')
  case "$CONFIRM_LOWER" in
    y|yes) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
else
  echo "Installer will COMPLETELY configure the remote server (apt, postgres, nginx). Continuing (non-interactive)."
fi

# --- Upload project ---
SSH_CMD=(sshpass -p "${REMOTE_PASS}" ssh -T -o StrictHostKeyChecking=no)

echo ">>> Uploading project to ${REMOTE_HOST}:${REMOTE_DIR}"
PASS_B64=$(printf '%s\n' "${REMOTE_PASS}" | base64 | tr -d '\n')

"${SSH_CMD[@]}" "${REMOTE_USER}@${REMOTE_HOST}" \
  "printf '%s' '${PASS_B64}' | base64 -d | sudo -S bash -c \"mkdir -p '${REMOTE_DIR}' && chown -R '${REMOTE_USER}:${REMOTE_USER}' '${REMOTE_DIR}'\""

sshpass -p "${REMOTE_PASS}" rsync -avz --delete \
  --exclude 'deploy copy*' \
  "${LOCAL_PROJECT_DIR}/" \
  "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"

# Build installer input (sudo password + interactive answers)
INSTALL_ANSWERS=(
  "${INSTALL_DIR_INPUT}"
  "${STREAM_DOMAIN}"
  "${STREAM_IP}"
  "${ADMIN_PASSWORD}"
  "${STREAMING_API_BASE}"
  "${STREAMING_API_TOKEN}"
  "${STREAMING_API_TIMEOUT}"
  "${CLOUDFLARE_ZONE_ID}"
  "${CLOUDFLARE_API_TOKEN}"
  "${POSTGRES_DB}"
  "${POSTGRES_USER}"
  "${POSTGRES_PASSWORD}"
)

ANSWERS_B64=$(printf '%s\n' "${INSTALL_ANSWERS[@]}" | base64 | tr -d '\n')

# --- Execute installer ---
REMOTE_INSTALL_SCRIPT_PATH="${REMOTE_DIR}/${INSTALL_SCRIPT}"

echo ">>> Running installer (this can take several minutes)..."
sshpass -p "${REMOTE_PASS}" ssh -T -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" <<EOF
cd ${REMOTE_DIR}
printf '%s' '${PASS_B64}' | base64 -d | sudo -S systemctl stop iptv-panel || true
printf '%s' '${PASS_B64}' | base64 -d | sudo -S systemctl stop nginx || true
printf '%s' '${PASS_B64}' | base64 -d | sudo -S rm -rf ${REMOTE_INSTALL_DIR}
chmod +x ${INSTALL_SCRIPT}
printf '%s' '${ANSWERS_B64}' | base64 -d > installer_answers.txt
EXIT_CODE=0
printf '%s' '${PASS_B64}' | base64 -d | sudo -S bash -c "./${INSTALL_SCRIPT} < installer_answers.txt" || EXIT_CODE=\$?
rm -f installer_answers.txt || true
exit \$EXIT_CODE
EOF

echo ">>> Installer finished. Checking service status..."
"${SSH_CMD[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "printf '%s' '${PASS_B64}' | base64 -d | sudo -S systemctl status iptv-panel --no-pager || true"

echo ">>> Configuring stream provisioning permissions..."
sshpass -p "${REMOTE_PASS}" ssh -T -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" <<EOF
TMP_SCRIPT=\$(mktemp)
cat <<'EOSCRIPT' > "\$TMP_SCRIPT"
set -e
STREAM_HOST="${STREAM_IP}"
STREAM_ROOT_PASS="${ADMIN_PASSWORD}"
KEY_DIR="/root/.ssh"
KEY_PATH="\${KEY_DIR}/id_rsa"

mkdir -p "\$KEY_DIR"
chmod 700 "\$KEY_DIR"

if [ ! -f "\$KEY_PATH" ]; then
  ssh-keygen -t rsa -b 4096 -N "" -f "\$KEY_PATH"
fi

if ! sshpass -p "\$STREAM_ROOT_PASS" ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@"\$STREAM_HOST" true 2>/dev/null; then
  sshpass -p "\$STREAM_ROOT_PASS" ssh-copy-id -o StrictHostKeyChecking=no -i "\${KEY_PATH}.pub" root@"\$STREAM_HOST" || true
fi

cat <<'EOC' >/etc/sudoers.d/iptvpanel-user-manager
iptvpanel ALL=(root) NOPASSWD: /opt/user_manager.sh
EOC
chmod 440 /etc/sudoers.d/iptvpanel-user-manager
EOSCRIPT
printf '%s\n' "${REMOTE_PASS}" | sudo -S bash "\$TMP_SCRIPT"
printf '%s\n' "${REMOTE_PASS}" | sudo -S rm -f "\$TMP_SCRIPT"
EOF

if [ -n "${PANEL_DOMAIN}" ] && [ -n "${CERTBOT_EMAIL}" ]; then
  echo ">>> Setting up SSL for ${PANEL_DOMAIN}..."
  REMOTE_SSL_SCRIPT_PATH="${REMOTE_DIR}/${REMOTE_SSL_SCRIPT}"
  sshpass -p "${REMOTE_PASS}" ssh -T -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" \
    "printf '%s' '${PASS_B64}' | base64 -d | sudo -S bash -c 'chmod +x ${REMOTE_SSL_SCRIPT_PATH} && ${REMOTE_SSL_SCRIPT_PATH} \"${PANEL_DOMAIN}\" \"${CERTBOT_EMAIL}\" \"${REMOTE_INSTALL_DIR}\" \"${ADMIN_PASSWORD}\"'"
fi

if [ -n "${PANEL_DOMAIN}" ] && [ -n "${CERTBOT_EMAIL}" ]; then
  echo ">>> Done. Visit https://${PANEL_DOMAIN}:54321/xui/ to confirm the panel is up."
else
  echo ">>> Done. Visit http://${REMOTE_HOST}:54321/xui/ to confirm the panel is up."
fi

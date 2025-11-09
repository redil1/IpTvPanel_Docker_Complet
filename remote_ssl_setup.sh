#!/usr/bin/env bash
set -euo pipefail

# Arguments:
# $1: PANEL_DOMAIN
# $2: CERTBOT_EMAIL
# $3: INSTALL_DIR
# $4: ADMIN_PASSWORD

PANEL_DOMAIN="$1"
CERTBOT_EMAIL="$2"
INSTALL_DIR="$3"
ADMIN_PASSWORD="$4"

CERT_PATH="/etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem"

apt-get install -y certbot >/dev/null
systemctl stop nginx || true
systemctl stop iptv-panel || true

if certbot certonly --standalone --non-interactive --agree-tos --email ${CERTBOT_EMAIL} --keep-until-expiring -d ${PANEL_DOMAIN}; then
    echo "Certbot certificate issued."
else
    echo "Certbot failed; generating self-signed certificate."
    SELF_DIR="/etc/iptv-panel-selfsigned"
    CERT_PATH="${SELF_DIR}/${PANEL_DOMAIN}.crt"
    KEY_PATH="${SELF_DIR}/${PANEL_DOMAIN}.key"
    mkdir -p ${SELF_DIR}
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout ${KEY_PATH} -out ${CERT_PATH} -subj "/CN=${PANEL_DOMAIN}"
fi

cat <<NGINX > "${INSTALL_DIR}/config/nginx.conf"
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    return 301 https://${PANEL_DOMAIN}:54321\$request_uri;
}

server {
    listen 443 ssl;
    listen 54321 ssl;
    server_name ${PANEL_DOMAIN};

    ssl_certificate     ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location /xui/static/ {
        alias ${INSTALL_DIR}/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    location /static/ {
        alias ${INSTALL_DIR}/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    location /xui/ {
        rewrite ^/xui/(.*)\$ /\$1 break;
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX

cp "${INSTALL_DIR}/config/nginx.conf" /etc/nginx/sites-available/iptv-panel
nginx -t
systemctl start iptv-panel
systemctl restart nginx

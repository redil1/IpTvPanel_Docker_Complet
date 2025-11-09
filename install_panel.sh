#!/bin/bash
#
# ========================================================================================
# IPTV Panel Autopilot Installer
# ========================================================================================
# This script automates the complete deployment of the IPTV Panel on a fresh
# Debian-based server (Ubuntu 22.04+ recommended).
#
# It handles system dependencies, PostgreSQL setup, Python environment,
# application configuration, Nginx reverse proxy, Supervisor process management,
# and SSL certificate generation with Let's Encrypt.
#
# USAGE:
# 1. Place this script in the root of the IptvPannel project directory.
# 2. Make it executable: chmod +x install_panel.sh
# 3. Run as root: sudo ./install_panel.sh
# ========================================================================================

set -e
# set -x # Uncomment for debugging

# --- Step 0: Configuration & Pre-flight Checks ---

# ---!!!--- CONFIGURE THESE VALUES BEFORE RUNNING ---!!!---
# Domain must point to this server's IP address for SSL to work.
PANEL_DOMAIN="panel.yourdomain.com"
CERTBOT_EMAIL="youremail@yourdomain.com"

# Streaming Server Details (can be configured later in the panel settings)
STREAM_DOMAIN="stream.yourdomain.com"
STREAM_IP="1.2.3.4"

# --- Autopilot-Generated Secrets ---
# These will be generated automatically.
DB_NAME="iptv_panel"
DB_USER="iptv_admin"
DB_PASS=$(openssl rand -hex 16)
ADMIN_PASSWORD=$(openssl rand -hex 16)
SECRET_KEY=$(openssl rand -hex 32)
ADMIN_API_TOKEN=$(openssl rand -hex 32)

# --- System Configuration ---
APP_USER="iptvpanel"
APP_GROUP="iptvpanel"
INSTALL_DIR="/opt/iptvpanel"
LOG_DIR="${INSTALL_DIR}/logs"
VENV_DIR="${INSTALL_DIR}/venv"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/local_panel"
SUMMARY_FILE="/root/iptv_panel_credentials.txt"

# --- Pre-flight Checks ---
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use 'sudo ./install_panel.sh'."
  exit 1
fi

if ! ping -c 1 -W 1 ${PANEL_DOMAIN} &> /dev/null; then
    echo "WARNING: Domain '${PANEL_DOMAIN}' does not seem to be reachable."
    read -p "This may cause SSL generation to fail. Continue anyway? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[yY](es)?$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

if [ ! -d "${SOURCE_DIR}" ]; then
    echo "ERROR: Source directory '${SOURCE_DIR}' not found."
    echo "Please ensure this script is in the root of the IptvPannel project directory."
    exit 1
fi

echo "--- IPTV Panel Autopilot Installer ---"
echo "This script will install and configure the entire panel stack."
echo "Installation Directory: ${INSTALL_DIR}"
echo "Panel Domain: ${PANEL_DOMAIN}"
echo "----------------------------------------"
read -p "Press [Enter] to begin the installation..."


# --- Step 1: System Preparation & Dependencies ---
echo ">>> Step 1: Installing system dependencies..."
apt-get update
apt-get install -y \
    python3 python3-venv python3-pip \
    postgresql postgresql-contrib \
    nginx \
    supervisor \
    certbot python3-certbot-nginx \
    openssl

# Create dedicated application user
if ! id -u ${APP_USER} >/dev/null 2>&1; then
    echo "Creating application user '${APP_USER}'..."
    useradd -r -s /bin/false ${APP_USER}
fi
if ! getent group ${APP_GROUP} >/dev/null 2>&1; then
    echo "Creating application group '${APP_GROUP}'..."
    groupadd -r ${APP_GROUP}
    usermod -a -G ${APP_GROUP} ${APP_USER}
fi


# --- Step 2: Database Setup (PostgreSQL) ---
echo ">>> Step 2: Configuring PostgreSQL database..."
# Start and enable PostgreSQL service
systemctl start postgresql
systemctl enable postgresql

# Create database and user
sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME};" || echo "Database ${DB_NAME} already exists."
sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';" || echo "User ${DB_USER} already exists. Setting new password."
sudo -u postgres psql -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"
sudo -u postgres psql -c "ALTER ROLE ${DB_USER} SET client_encoding TO 'utf8';"
sudo -u postgres psql -c "ALTER ROLE ${DB_USER} SET default_transaction_isolation TO 'read committed';"
sudo -u postgres psql -c "ALTER ROLE ${DB_USER} SET timezone TO 'UTC';"


# --- Step 3: Application Code & Environment ---
echo ">>> Step 3: Setting up application environment..."
# Create directories
mkdir -p ${INSTALL_DIR} ${LOG_DIR}
# Copy application code
rsync -a --delete "${SOURCE_DIR}/" "${INSTALL_DIR}/"
# Set ownership
chown -R ${APP_USER}:${APP_GROUP} ${INSTALL_DIR}

# Create Python virtual environment
echo "Creating Python virtual environment..."
python3 -m venv ${VENV_DIR}
# Install dependencies
echo "Installing Python dependencies..."
${VENV_DIR}/bin/pip install --upgrade pip
${VENV_DIR}/bin/pip install -r ${INSTALL_DIR}/requirements.txt


# --- Step 4: Application Configuration (.env & DB Init) ---
echo ">>> Step 4: Configuring application..."
# Create .env file
DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@localhost/${DB_NAME}"
cat > ${INSTALL_DIR}/.env << EOF
# IPTV Panel Environment Configuration
# Generated by install_panel.sh on $(date)

# Flask Settings
SECRET_KEY=${SECRET_KEY}
SQLALCHEMY_DATABASE_URI=${DATABASE_URL}
SQLALCHEMY_TRACK_MODIFICATIONS=False

# Admin Credentials & API
ADMIN_PASSWORD=${ADMIN_PASSWORD}
ADMIN_API_TOKEN=${ADMIN_API_TOKEN}

# Streaming Server Details (placeholders)
STREAM_DOMAIN=${STREAM_DOMAIN}
STREAM_SERVER_IP=${STREAM_IP}

# Cloudflare API (optional, configure in panel UI)
CLOUDFLARE_API_TOKEN=
CLOUDFLARE_ZONE_ID=

# Streaming Service API (optional, configure in panel UI)
STREAMING_API_BASE_URL=
STREAMING_API_TOKEN=
EOF

# Set ownership of .env file
chown ${APP_USER}:${APP_GROUP} ${INSTALL_DIR}/.env
chmod 640 ${INSTALL_DIR}/.env

# Initialize the database
echo "Initializing database schema and default admin..."
cd ${INSTALL_DIR}
# Set the flask app environment variable
export FLASK_APP=app.py
# Run migrations
${VENV_DIR}/bin/flask db upgrade
# Run the init function to create admin user and settings
${VENV_DIR}/bin/python -c "from app import init_db; init_db()"


# --- Step 5: Supervisor Configuration ---
echo ">>> Step 5: Configuring Supervisor service..."
cat > /etc/supervisor/conf.d/iptvpanel.conf << EOF
[program:iptv-panel]
command=${VENV_DIR}/bin/gunicorn -w 4 -b 127.0.0.1:5000 --timeout 120 app:app
directory=${INSTALL_DIR}
user=${APP_USER}
autostart=true
autorestart=true
stderr_logfile=${LOG_DIR}/error.log
stdout_logfile=${LOG_DIR}/access.log
environment=PATH="${VENV_DIR}/bin"
EOF

# Reload supervisor
supervisorctl reread
supervisorctl update
supervisorctl start iptv-panel


# --- Step 6: Nginx & SSL Configuration ---
echo ">>> Step 6: Configuring Nginx and SSL..."
# Create Nginx config
cat > /etc/nginx/sites-available/iptvpanel << EOF
server {
    listen 80;
    server_name ${PANEL_DOMAIN};

    # Redirect all HTTP to HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}
EOF

# Enable the site
ln -sfn /etc/nginx/sites-available/iptvpanel /etc/nginx/sites-enabled/iptvpanel

# Test Nginx config
nginx -t

# Obtain SSL certificate
echo "Requesting SSL certificate from Let's Encrypt..."
certbot --nginx -d ${PANEL_DOMAIN} --non-interactive --agree-tos -m ${CERTBOT_EMAIL} --redirect

# Certbot automatically reloads nginx on success.
# We will add our proxy pass configuration to the SSL server block created by certbot.
# This is more robust than modifying the template before certbot runs.

# The file is typically named the same as the site file.
NGINX_SSL_CONFIG="/etc/nginx/sites-available/iptvpanel"
if [ -f "/etc/nginx/sites-enabled/iptvpanel-le-ssl.conf" ]; then
    # Some systems create a new file for SSL
    NGINX_SSL_CONFIG="/etc/nginx/sites-enabled/iptvpanel-le-ssl.conf"
fi

# Add proxy and static file configuration
# Using awk to insert after the 'server_name' line in the ssl server block
awk '/ssl_certificate/ {
    print;
    print "\n    location / {";
    print "        proxy_pass http://127.0.0.1:5000;";
    print "        proxy_set_header Host $host;";
    print "        proxy_set_header X-Real-IP $remote_addr;";
    print "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;";
    print "        proxy_set_header X-Forwarded-Proto $scheme;";
    print "    }\n";
    print "    location /static {";
    print "        alias '${INSTALL_DIR}/static';";
    print "        expires 30d;";
    print "        add_header Cache-Control \"public, immutable\";";
    print "    }";
    next
}1' ${NGINX_SSL_CONFIG} > ${NGINX_SSL_CONFIG}.tmp && mv ${NGINX_SSL_CONFIG}.tmp ${NGINX_SSL_CONFIG}


# Test and reload Nginx again
nginx -t
systemctl reload nginx


# --- Step 7: Firewall ---
echo ">>> Step 7: Configuring firewall..."
ufw allow ssh
ufw allow 'Nginx Full'
ufw --force enable


# --- Step 8: Finalization ---
echo ">>> Step 8: Installation complete!"
echo "-----------------------------------------------------------------"
echo "Panel URL: https://${PANEL_DOMAIN}"
echo "Admin Username: admin"
echo "Admin Password: ${ADMIN_PASSWORD}"
echo ""
echo "Database Name: ${DB_NAME}"
echo "Database User: ${DB_USER}"
echo "Database Password: ${DB_PASS}"
echo ""
echo "A summary of these credentials has been saved to:"
echo "${SUMMARY_FILE}"
echo "-----------------------------------------------------------------"

# Save credentials to summary file
cat > ${SUMMARY_FILE} << EOF
# IPTV Panel Installation Summary
# Generated on $(date)

[Panel Access]
URL: https://${PANEL_DOMAIN}
Username: admin
Password: ${ADMIN_PASSWORD}

[Database Credentials]
Database Name: ${DB_NAME}
Database User: ${DB_USER}
Database Password: ${DB_PASS}
Connection URL: ${DATABASE_URL}

[API Token]
Admin API Token: ${ADMIN_API_TOKEN}
(For use with user_manager.sh or other scripts)

[System]
Install Directory: ${INSTALL_DIR}
Log Directory: ${LOG_DIR}
Supervisor Config: /etc/supervisor/conf.d/iptvpanel.conf
Nginx Config: /etc/nginx/sites-enabled/iptvpanel
EOF

chmod 600 ${SUMMARY_FILE}

echo "Autopilot installation finished successfully."
exit 0

#!/bin/bash
################################################################################
# IPTV Panel - Master File Generator
# This script creates ALL files needed for the IPTV management panel
# Version: 1.0.0
# 
# Usage: 
#   chmod +x create_all_files.sh
#   ./create_all_files.sh
################################################################################

set -euo pipefail
IFS=$'\n\t'

# Utility helpers
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo -e "${RED}Error:${NC} Required command '$1' not found in PATH."
        echo "Please install '$1' and rerun the installer."
        exit 1
    fi
}

# Clear screen only when running in a real terminal
if [ -t 1 ]; then
    if command -v tput >/dev/null 2>&1; then
        tput reset
    elif command -v clear >/dev/null 2>&1; then
        clear
    fi
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
echo -e "${BLUE}"
cat << "EOF"
╔════════════════════════════════════════════════════════════╗
║                                                            ║
║        IPTV PANEL - MASTER FILE GENERATOR                  ║
║        Complete System Creator v1.0                        ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Ensure script runs as root (required for package/service management)
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error:${NC} Please run this installer as root (use sudo)."
    exit 1
fi

# Default service account for running the panel
APP_USER="iptvpanel"
APP_GROUP="$APP_USER"

# Configuration
read -p "Enter installation directory [/opt/iptv-panel]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/opt/iptv-panel}

read -p "Enter streaming server domain (e.g., stream.yourdomain.com): " STREAM_DOMAIN
read -p "Enter streaming server IP: " STREAM_IP
read -sp "Enter admin password: " ADMIN_PASS
echo ""

read -p "Enter streaming API base URL (e.g., https://stream.yourdomain.com/api) [skip]: " STREAMING_API_BASE_URL
read -p "Enter streaming API token/key [skip]: " STREAMING_API_TOKEN
read -p "Streaming API timeout seconds [10]: " STREAMING_API_TIMEOUT
STREAMING_API_TIMEOUT=${STREAMING_API_TIMEOUT:-10}

read -p "Enter Cloudflare Zone ID [skip]: " CLOUDFLARE_ZONE_ID
read -p "Enter Cloudflare API token [skip]: " CLOUDFLARE_API_TOKEN
if [ -n "$STREAMING_API_BASE_URL" ]; then
    STREAMING_API_BASE_URL=${STREAMING_API_BASE_URL%/}
fi

read -p "Enter PostgreSQL database name [iptv_panel]: " POSTGRES_DB
POSTGRES_DB=${POSTGRES_DB:-iptv_panel}
read -p "Enter PostgreSQL username [iptv_admin]: " POSTGRES_USER
POSTGRES_USER=${POSTGRES_USER:-iptv_admin}
read -sp "Enter PostgreSQL password [auto-generate]: " POSTGRES_PASSWORD
if [ -z "$POSTGRES_PASSWORD" ]; then
    POSTGRES_PASSWORD=$(openssl rand -hex 16)
    echo ""
    echo -e "${YELLOW}Generated PostgreSQL password:${NC} $POSTGRES_PASSWORD"
else
    echo ""
fi

# Validate basic prerequisites
require_cmd openssl

# Prepare installation directory
if [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
    read -p "Warning: $INSTALL_DIR is not empty. Continue and overwrite files? [y/N]: " CONFIRM
    case "${CONFIRM,,}" in
        y|yes) ;;
        *) echo "Aborting installation."; exit 1 ;;
    esac
fi

mkdir -p "$INSTALL_DIR"

LOG_FILE="$INSTALL_DIR/installation.log"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
echo -e "${YELLOW}Logging installation to $LOG_FILE${NC}"

# Install system dependencies
echo -e "${YELLOW}[SYS] Updating package index...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

echo -e "${YELLOW}[SYS] Installing required packages...${NC}"
apt-get install -y \
    python3 python3-venv python3-dev python3-pip \
    build-essential libpq-dev \
    postgresql postgresql-contrib \
    nginx \
    openssl \
    sshpass \
    git curl unzip

systemctl enable postgresql >/dev/null 2>&1 || true
systemctl enable nginx >/dev/null 2>&1 || true
systemctl enable supervisor >/dev/null 2>&1 || true

if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd --system --create-home --shell /bin/bash "$APP_USER"
fi

# Configure PostgreSQL database and user
echo -e "${YELLOW}[SYS] Configuring PostgreSQL...${NC}"
runuser -u postgres -- psql -tc "SELECT 1 FROM pg_roles WHERE rolname = '${POSTGRES_USER}'" | grep -q 1 || \
    runuser -u postgres -- psql -c "CREATE ROLE ${POSTGRES_USER} WITH LOGIN PASSWORD '${POSTGRES_PASSWORD}';"
runuser -u postgres -- psql -c "ALTER ROLE ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASSWORD}';"

runuser -u postgres -- psql -tc "SELECT 1 FROM pg_database WHERE datname = '${POSTGRES_DB}'" | grep -q 1 || \
    runuser -u postgres -- psql -c "CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER};"

runuser -u postgres -- psql -c "GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_USER};" >/dev/null

# Create .pgpass for the application user
APP_HOME=$(getent passwd "$APP_USER" | cut -d: -f6)
PGPASS_FILE="$APP_HOME/.pgpass"
echo "localhost:5432:${POSTGRES_DB}:${POSTGRES_USER}:${POSTGRES_PASSWORD}" > "$PGPASS_FILE"
chown "$APP_USER:$APP_GROUP" "$PGPASS_FILE"
chmod 600 "$PGPASS_FILE"

# Create directory structure
echo -e "${YELLOW}[1/12] Creating directory structure...${NC}"
mkdir -p \
    "$INSTALL_DIR/database" \
    "$INSTALL_DIR/templates" \
    "$INSTALL_DIR/static/css" \
    "$INSTALL_DIR/static/js" \
    "$INSTALL_DIR/static/img" \
    "$INSTALL_DIR/logs" \
    "$INSTALL_DIR/backups" \
    "$INSTALL_DIR/config" \
    "$INSTALL_DIR/scripts" \
    "$INSTALL_DIR/services" \
    "$INSTALL_DIR/instance/database"
cd "$INSTALL_DIR"

################################################################################
# PYTHON FILES
################################################################################

echo -e "${YELLOW}[2/12] Creating database models...${NC}"
cat > database/__init__.py << 'EOF'
# Database package initialization
EOF

cat > database/models.py << 'EOF'
"""
IPTV Panel Database Models
Complete schema for IPTV management system
"""
from flask_sqlalchemy import SQLAlchemy
from flask_login import UserMixin
from datetime import datetime, timedelta
import secrets
import bcrypt

db = SQLAlchemy()

class Admin(UserMixin, db.Model):
    """Admin users for panel access"""
    __tablename__ = 'admins'
    
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(50), unique=True, nullable=False)
    password_hash = db.Column(db.String(255), nullable=False)
    email = db.Column(db.String(100))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_login = db.Column(db.DateTime)
    
    def set_password(self, password):
        self.password_hash = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
    
    def check_password(self, password):
        return bcrypt.checkpw(password.encode('utf-8'), self.password_hash.encode('utf-8'))


class User(db.Model):
    """IPTV subscribers"""
    __tablename__ = 'users'
    
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(50), unique=True, nullable=False, index=True)
    password = db.Column(db.String(100), nullable=False)
    email = db.Column(db.String(100))
    token = db.Column(db.String(64), unique=True, nullable=False, index=True)
    
    is_active = db.Column(db.Boolean, default=True, index=True)
    expiry_date = db.Column(db.DateTime, nullable=False, index=True)
    max_connections = db.Column(db.Integer, default=1)
    
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_access = db.Column(db.DateTime)
    total_bandwidth_mb = db.Column(db.Integer, default=0)
    notes = db.Column(db.Text)
    
    connections = db.relationship('Connection', backref='user', lazy=True, cascade='all, delete-orphan')
    
    def generate_token(self, char_length=64):
        try:
            char_length = int(char_length)
        except (TypeError, ValueError):
            char_length = 64
        self.token = secrets.token_hex(max(16, char_length) // 2)
    
    def is_expired(self):
        return datetime.utcnow() > self.expiry_date
    
    def days_remaining(self):
        if self.is_expired():
            return 0
        return (self.expiry_date - datetime.utcnow()).days
    
    def extend_subscription(self, days):
        if self.is_expired():
            self.expiry_date = datetime.utcnow() + timedelta(days=days)
        else:
            self.expiry_date += timedelta(days=days)


class Connection(db.Model):
    """Active connections tracking"""
    __tablename__ = 'connections'
    
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey('users.id'), nullable=False, index=True)
    ip_address = db.Column(db.String(45))
    user_agent = db.Column(db.String(255))
    channel_id = db.Column(db.String(50))
    connected_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_heartbeat = db.Column(db.DateTime, default=datetime.utcnow, index=True)
    
    def is_active(self):
        if not self.last_heartbeat:
            return False
        return (datetime.utcnow() - self.last_heartbeat).seconds < 120


class Channel(db.Model):
    """Available channels"""
    __tablename__ = 'channels'
    
    id = db.Column(db.Integer, primary_key=True)
    channel_id = db.Column(db.String(50), unique=True, nullable=False, index=True)
    name = db.Column(db.String(100), nullable=False)
    category = db.Column(db.String(50), default='General', index=True)
    source_url = db.Column(db.String(500), nullable=False)
    logo_url = db.Column(db.String(500))
    is_active = db.Column(db.Boolean, default=True, index=True)
    quality = db.Column(db.String(20), default='medium')
    epg_id = db.Column(db.String(100))
    view_count = db.Column(db.Integer, default=0)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    
    def increment_views(self):
        self.view_count += 1
        db.session.commit()


class SystemLog(db.Model):
    """System logs"""
    __tablename__ = 'logs'
    
    id = db.Column(db.Integer, primary_key=True)
    timestamp = db.Column(db.DateTime, default=datetime.utcnow, index=True)
    level = db.Column(db.String(20), index=True)
    category = db.Column(db.String(50), index=True)
    message = db.Column(db.Text)
    ip_address = db.Column(db.String(45))
    
    @staticmethod
    def log(level, category, message, ip=None):
        log = SystemLog(level=level, category=category, message=message, ip_address=ip)
        db.session.add(log)
        db.session.commit()


class Settings(db.Model):
    """System settings"""
    __tablename__ = 'settings'
    
    key = db.Column(db.String(100), primary_key=True)
    value = db.Column(db.Text)
    description = db.Column(db.String(255))
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    @staticmethod
    def get(key, default=None):
        setting = Settings.query.get(key)
        return setting.value if setting else default
    
    @staticmethod
    def set(key, value, description=None):
        setting = Settings.query.get(key)
        if setting:
            setting.value = value
            if description:
                setting.description = description
        else:
            setting = Settings(key=key, value=value, description=description)
            db.session.add(setting)
        db.session.commit()

EOF

echo -e "${YELLOW}[3a/12] Creating integration services...${NC}"
cat > services/__init__.py << 'EOFSERVINIT'
"""Service layer exposing external integrations."""
from .streaming import StreamingService
from .cloudflare import CloudflareService

__all__ = ("StreamingService", "CloudflareService")
EOFSERVINIT

cat > services/streaming.py << 'EOFSTREAM'
"""Integration helpers for the remote streaming server."""
from __future__ import annotations

import logging
import os
from typing import Dict, Tuple, Any

import requests

LOGGER = logging.getLogger(__name__)


def _config() -> Dict[str, Any]:
    """Return streaming API configuration derived from environment variables."""
    base = (os.environ.get("STREAMING_API_BASE_URL", "") or "").strip()
    if base.endswith("/"):
        base = base.rstrip("/")
    token = (os.environ.get("STREAMING_API_TOKEN", "") or "").strip()
    timeout_raw = os.environ.get("STREAMING_API_TIMEOUT", "") or "10"
    try:
        timeout = int(timeout_raw)
    except (TypeError, ValueError):
        timeout = 10
    user_endpoint = (os.environ.get("STREAMING_API_USER_ENDPOINT", "/api/users") or "/api/users").strip()
    channel_endpoint = (os.environ.get("STREAMING_API_CHANNEL_ENDPOINT", "/api/channels") or "/api/channels").strip()
    if not user_endpoint.startswith("/"):
        user_endpoint = f"/{user_endpoint}"
    if not channel_endpoint.startswith("/"):
        channel_endpoint = f"/{channel_endpoint}"
    return {
        "base": base,
        "token": token,
        "timeout": timeout if timeout > 0 else 10,
        "user_endpoint": user_endpoint.rstrip("/"),
        "channel_endpoint": channel_endpoint.rstrip("/"),
    }


def _request(method: str, path: str, *, json: Dict[str, Any] | None = None) -> Tuple[bool, Any]:
    """Perform an authenticated HTTP request against the streaming API."""
    cfg = _config()
    if not cfg["base"] or not cfg["token"]:
        return True, "Streaming API not configured"

    url = f'{cfg["base"]}{path}'
    headers = {
        "Authorization": f'Bearer {cfg["token"]}',
        "Content-Type": "application/json",
    }

    try:
        response = requests.request(
            method,
            url,
            json=json,
            timeout=cfg["timeout"],
            headers=headers,
        )
        response.raise_for_status()
        if response.content and "application/json" in response.headers.get("Content-Type", ""):
            return True, response.json()
        return True, response.text or "ok"
    except Exception as exc:  # noqa: BLE001
        LOGGER.exception("Streaming API request failed: %s %s", method, url)
        return False, str(exc)


class StreamingService:
    """Operations for syncing subscribers and channels to the streaming backend."""

    @staticmethod
    def sync_user(user, action: str) -> Tuple[bool, Any]:
        """Create, update, or delete a user on the streaming server."""
        cfg = _config()
        endpoint = cfg["user_endpoint"]
        payload = {
            "username": user.username,
            "password": user.password,
            "token": user.token,
            "email": getattr(user, "email", ""),
            "max_connections": getattr(user, "max_connections", 1),
            "is_active": getattr(user, "is_active", True),
            "expires_at": getattr(user, "expiry_date", None).isoformat() if getattr(user, "expiry_date", None) else None,
        }

        if action == "create":
            return _request("POST", endpoint, json=payload)
        if action == "update":
            return _request("PUT", f"{endpoint}/{user.username}", json=payload)
        if action == "delete":
            return _request("DELETE", f"{endpoint}/{user.username}")
        return False, f"Unsupported user sync action: {action}"

    @staticmethod
    def sync_channel(channel, action: str) -> Tuple[bool, Any]:
        """Create, update, or delete a channel definition on the streaming server."""
        cfg = _config()
        endpoint = cfg["channel_endpoint"]
        payload = {
            "channel_id": channel.channel_id,
            "name": channel.name,
            "category": channel.category,
            "source_url": channel.source_url,
            "logo_url": getattr(channel, "logo_url", ""),
            "is_active": getattr(channel, "is_active", True),
            "quality": getattr(channel, "quality", "medium"),
        }

        if action == "create":
            return _request("POST", endpoint, json=payload)
        if action == "update":
            return _request("PUT", f"{endpoint}/{channel.channel_id}", json=payload)
        if action == "delete":
            return _request("DELETE", f"{endpoint}/{channel.channel_id}")
        return False, f"Unsupported channel sync action: {action}"
EOFSTREAM

cat > services/cloudflare.py << 'EOFCLOUDFLARE'
"""Cloudflare cache management helpers."""
from __future__ import annotations

import logging
import os
from typing import Iterable, List, Tuple, Any

import requests

LOGGER = logging.getLogger(__name__)
API_BASE = "https://api.cloudflare.com/client/v4"


def _config() -> Tuple[str, str]:
    zone_id = (os.environ.get("CLOUDFLARE_ZONE_ID", "") or "").strip()
    token = (os.environ.get("CLOUDFLARE_API_TOKEN", "") or "").strip()
    return zone_id, token


def _normalize_domain(domain: str | None) -> str | None:
    if not domain:
        return None
    domain = domain.strip()
    if not domain:
        return None
    if not domain.startswith("http://") and not domain.startswith("https://"):
        domain = f"https://{domain}"
    return domain.rstrip("/")


def _build_full_url(domain: str | None, path: str) -> str | None:
    normalized = _normalize_domain(domain)
    if not normalized:
        return None
    return f"{normalized}/{path.lstrip('/')}"


class CloudflareService:
    """Wrapper around the Cloudflare purge API."""

    @staticmethod
    def purge_urls(urls: Iterable[str]) -> Tuple[bool, Any]:
        url_list = [u for u in urls if u]
        if not url_list:
            return True, "No URLs provided"

        zone_id, token = _config()
        if not zone_id or not token:
            return True, "Cloudflare not configured"

        endpoint = f"{API_BASE}/zones/{zone_id}/purge_cache"
        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        }

        try:
            response = requests.post(endpoint, headers=headers, json={"files": url_list}, timeout=15)
            response.raise_for_status()
            data = response.json()
            if data.get("success", True):
                return True, data
            return False, data.get("errors", data)
        except Exception as exc:  # noqa: BLE001
            LOGGER.exception("Cloudflare purge failed for %s", url_list)
            return False, str(exc)

    @staticmethod
    def playlist_urls(domain: str, tokens: Iterable[str]) -> List[str]:
        return [_build_full_url(domain, f"playlist/{token}.m3u8") for token in tokens]

    @staticmethod
    def channel_urls(domain: str, channel_id: str) -> List[str]:
        return [
            _build_full_url(domain, f"live/stream_{channel_id}.m3u8"),
            _build_full_url(domain, f"live/{channel_id}.m3u8"),
        ]
EOFCLOUDFLARE

echo -e "${YELLOW}[3/12] Creating main application...${NC}"
cat > app.py << 'EOFAPP'
"""
IPTV Panel - Main Application
Professional IPTV management system
"""
from flask import Flask, render_template, request, redirect, url_for, flash, jsonify, send_file, abort, has_request_context, current_app
from flask_login import LoginManager, login_user, logout_user, login_required, current_user
from flask_migrate import Migrate
from datetime import datetime, timedelta
from functools import wraps
from pathlib import Path
import secrets
import os
import re
import json
import subprocess
from dotenv import load_dotenv

from database.models import db, Admin, User, Connection, Channel, SystemLog, Settings

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / '.env')

from services.streaming import StreamingService
from services.cloudflare import CloudflareService

app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', secrets.token_hex(32))
app.config['SQLALCHEMY_DATABASE_URI'] = os.environ.get('DATABASE_URL', 'sqlite:///database/iptv_panel.db')
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['SQLALCHEMY_ENGINE_OPTIONS'] = {'pool_pre_ping': True, 'pool_recycle': 300}

ADMIN_API_TOKEN = os.environ.get('ADMIN_API_TOKEN', '').strip()

db.init_app(app)
migrate = Migrate(app, db)
login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'

@login_manager.user_loader
def load_user(user_id):
    return Admin.query.get(int(user_id))

# Context processor for templates
@app.context_processor
def inject_globals():
    return {
        'now': datetime.utcnow(),
        'app_name': Settings.get('server_name', 'IPTV Panel'),
        'version': '1.0.0',
        'Settings': Settings
    }


def _external_ip():
    return request.remote_addr if has_request_context() else None


def _log_external(service: str, success: bool, message: str, detail: str = '') -> None:
    entry = message if success or not detail else f"{message} - {detail}"
    level = 'INFO' if success else 'ERROR'
    SystemLog.log(level, service, entry, _external_ip())


def sync_user_with_streaming(user, action: str) -> tuple[bool, str]:
    success, detail = StreamingService.sync_user(user, action)
    action_label = f"{action.capitalize()} user {user.username}"
    _log_external('STREAMING', success, action_label, str(detail))
    return success, str(detail)


def sync_channel_with_streaming(channel, action: str) -> tuple[bool, str]:
    success, detail = StreamingService.sync_channel(channel, action)
    action_label = f"{action.capitalize()} channel {channel.channel_id}"
    _log_external('STREAMING', success, action_label, str(detail))
    return success, str(detail)


def purge_playlist_cache(tokens: list[str], domain: str | None = None) -> tuple[bool, str]:
    domain = domain or Settings.get('stream_domain', request.host if has_request_context() else '')
    success, detail = CloudflareService.purge_urls(CloudflareService.playlist_urls(domain, tokens))
    _log_external('CLOUDFLARE', success, f"Purge playlist cache ({', '.join(tokens)})", str(detail))
    return success, str(detail)


def purge_channel_cache(channel_id: str, domain: str | None = None) -> tuple[bool, str]:
    domain = domain or Settings.get('stream_domain', request.host if has_request_context() else '')
    success, detail = CloudflareService.purge_urls(CloudflareService.channel_urls(domain, channel_id))
    _log_external('CLOUDFLARE', success, f"Purge channel cache ({channel_id})", str(detail))
    return success, str(detail)


def create_stream_user_via_script(username: str, days: int) -> tuple[dict | None, str]:
    command = ["sudo", "/opt/user_manager.sh", "create", username, str(days)]
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
    except FileNotFoundError:
        current_app.logger.error("user manager script not found at %s", command[0])
        return None, "User manager script not found"
    except subprocess.CalledProcessError as exc:
        message = (exc.stderr or exc.stdout or str(exc)).strip()
        current_app.logger.error("user manager script failed: %s", message)
        return None, message
    except Exception as exc:  # noqa: BLE001
        current_app.logger.exception("user manager script execution error")
        return None, str(exc)

    output = result.stdout.strip()
    data = {'raw_output': output}
    for line in output.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip().lower()
        value = value.strip()
        if key == "password":
            data['password'] = value
        elif key == "token":
            data['token'] = value
        elif key == "m3u url":
            data['m3u_url'] = value
        elif key == "expires":
            data['expires'] = value
        elif key == "username":
            data['username'] = value
    if 'token' not in data:
        current_app.logger.warning("user manager output missing token for %s: %s", username, output)
    return data, output


def apply_m3u_template_from_url(m3u_url: str | None, token: str | None) -> None:
    if not m3u_url or not token or token not in m3u_url:
        return
    template = m3u_url.replace(token, '{TOKEN}')
    if Settings.get('m3u_url_format') != template:
        Settings.set('m3u_url_format', template)


def get_token_length() -> int:
    try:
        return max(16, int(Settings.get('token_length', '64') or 64))
    except (TypeError, ValueError):
        return 64


@app.before_request
def enforce_setup_wizard():
    if not current_user.is_authenticated:
        return
    if Settings.get('setup_complete') == 'true':
        return
    # allow wizard and auth endpoints while incomplete
    allowed = {'static', 'setup_wizard', 'logout'}
    endpoint = request.endpoint
    if endpoint is None or endpoint in allowed:
        return
    return redirect(url_for('setup_wizard'))

# ============================================================================
# ADMIN ROUTES
# ============================================================================

@app.route('/')
@login_required
def dashboard():
    total_users = User.query.count()
    active_users = User.query.filter(User.is_active == True, User.expiry_date > datetime.utcnow()).count()
    expired_users = User.query.filter(User.expiry_date <= datetime.utcnow()).count()
    total_channels = Channel.query.filter_by(is_active=True).count()
    
    recent_users = User.query.order_by(User.created_at.desc()).limit(10).all()
    
    active_connections = Connection.query.filter(
        Connection.last_heartbeat > datetime.utcnow() - timedelta(minutes=2)
    ).count()
    
    recent_logs = SystemLog.query.order_by(SystemLog.timestamp.desc()).limit(10).all()
    
    expiring_soon = User.query.filter(
        User.is_active == True,
        User.expiry_date > datetime.utcnow(),
        User.expiry_date < datetime.utcnow() + timedelta(days=7)
    ).order_by(User.expiry_date).all()
    
    return render_template('dashboard.html',
        total_users=total_users,
        active_users=active_users,
        expired_users=expired_users,
        total_channels=total_channels,
        recent_users=recent_users,
        active_connections=active_connections,
        recent_logs=recent_logs,
        expiring_soon=expiring_soon
    )

@app.route('/login', methods=['GET', 'POST'])
def login():
    if current_user.is_authenticated:
        return redirect(url_for('dashboard'))
    
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        
        admin = Admin.query.filter_by(username=username).first()
        
        if admin and admin.check_password(password):
            login_user(admin)
            admin.last_login = datetime.utcnow()
            db.session.commit()
            SystemLog.log('INFO', 'AUTH', f'Admin {username} logged in', request.remote_addr)
            return redirect(url_for('dashboard'))
        else:
            flash('Invalid username or password', 'danger')
            SystemLog.log('WARNING', 'AUTH', f'Failed login for {username}', request.remote_addr)
    
    return render_template('login.html')

@app.route('/logout')
@login_required
def logout():
    SystemLog.log('INFO', 'AUTH', f'Admin {current_user.username} logged out', request.remote_addr)
    logout_user()
    return redirect(url_for('login'))


@app.route('/xui/')
def xui_root():
    if current_user.is_authenticated:
        return redirect(url_for('dashboard'))
    return redirect(url_for('login'))


@app.route('/setup', methods=['GET', 'POST'])
@login_required
def setup_wizard():
    if Settings.get('setup_complete') == 'true':
        return redirect(url_for('dashboard'))

    step = request.args.get('step', '1')
    try:
        step = int(step)
    except ValueError:
        step = 1

    server_name = Settings.get('server_name', 'Main Panel')
    timezone = Settings.get('timezone', 'UTC')
    language = Settings.get('language', 'English')

    streaming_config = Settings.get('streaming_server_config', '{}')
    try:
        streaming_config = json.loads(streaming_config)
    except json.JSONDecodeError:
        streaming_config = {}

    m3u_url_format = Settings.get('m3u_url_format', f"http://{Settings.get('stream_domain', request.host)}/live/stream_{{CHANNEL_ID}}.m3u8?token={{TOKEN}}")
    token_type = Settings.get('token_type', 'user')
    token_length = Settings.get('token_length', '64')

    if request.method == 'POST':
        if step == 1:
            server_name = request.form.get('server_name', server_name)
            timezone = request.form.get('timezone', timezone)
            language = request.form.get('language', language)
            Settings.set('server_name', server_name)
            Settings.set('timezone', timezone)
            Settings.set('language', language)
            return redirect(url_for('setup_wizard', step=2))

        if step == 2:
            config = {
                'name': request.form.get('stream_server_name', streaming_config.get('name', 'Hetzner-Stream-01')),
                'ip': request.form.get('stream_server_ip', streaming_config.get('ip', '')),
                'port': request.form.get('stream_server_port', streaming_config.get('port', '80')),
                'type': request.form.get('stream_server_type', streaming_config.get('type', 'Load Balancer')),
                'protocol': request.form.get('stream_server_protocol', streaming_config.get('protocol', 'HTTP')),
                'status': request.form.get('stream_server_status', streaming_config.get('status', 'Active')),
            }
            Settings.set('streaming_server_config', json.dumps(config))
            return redirect(url_for('setup_wizard', step=3))

        if step == 3:
            m3u_url_format = request.form.get('m3u_url_format', m3u_url_format)
            token_type = request.form.get('token_type', token_type)
            token_length = request.form.get('token_length', token_length)
            Settings.set('m3u_url_format', m3u_url_format)
            Settings.set('token_type', token_type)
            Settings.set('token_length', token_length)
            Settings.set('setup_complete', 'true')
            flash('Initial setup complete!', 'success')
            return redirect(url_for('dashboard'))

    return render_template(
        'setup_wizard.html',
        step=step,
        server_name=server_name,
        timezone=timezone,
        language=language,
        streaming_config=streaming_config,
        m3u_url_format=m3u_url_format,
        token_type=token_type,
        token_length=token_length
    )

# ============================================================================
# USER MANAGEMENT
# ============================================================================

@app.route('/users')
@login_required
def users_list():
    page = request.args.get('page', 1, type=int)
    search = request.args.get('search', '')
    status = request.args.get('status', 'all')
    
    query = User.query
    
    if search:
        query = query.filter(
            (User.username.like(f'%{search}%')) | (User.email.like(f'%{search}%'))
        )
    
    if status == 'active':
        query = query.filter(User.is_active == True, User.expiry_date > datetime.utcnow())
    elif status == 'expired':
        query = query.filter(User.expiry_date <= datetime.utcnow())
    elif status == 'disabled':
        query = query.filter(User.is_active == False)
    
    users = query.order_by(User.created_at.desc()).paginate(page=page, per_page=20)
    
    return render_template('users_list.html', users=users, search=search, status=status)

@app.route('/users/add', methods=['GET', 'POST'])
@login_required
def users_add():
    if request.method == 'POST':
        username = request.form.get('username').strip()
        password = request.form.get('password') or secrets.token_urlsafe(12)
        email = request.form.get('email', '').strip()
        days = int(request.form.get('days', 30))
        max_connections = int(request.form.get('max_connections', 1))
        notes = request.form.get('notes', '').strip()
        
        if not username or len(username) < 3:
            flash('Username must be at least 3 characters', 'danger')
            return redirect(url_for('users_add'))
        
        if User.query.filter_by(username=username).first():
            flash('Username already exists', 'danger')
            return redirect(url_for('users_add'))
        
        user = User(
            username=username,
            password=password,
            email=email,
            expiry_date=datetime.utcnow() + timedelta(days=days),
            max_connections=max_connections,
            notes=notes
        )
        user.generate_token(get_token_length())
        
        db.session.add(user)
        db.session.commit()

        sync_success = False
        sync_detail = ''

        script_data, script_output = create_stream_user_via_script(user.username, days)
        if script_data and script_data.get('token'):
            updated = False
            if script_data.get('password'):
                user.password = script_data['password']
                updated = True
            if script_data.get('token'):
                user.token = script_data['token']
                updated = True
            if script_data.get('m3u_url'):
                apply_m3u_template_from_url(script_data.get('m3u_url'), script_data.get('token'))
                notes_entry = f"M3U URL: {script_data['m3u_url']}"
                existing_notes = user.notes or ''
                if notes_entry not in existing_notes:
                    user.notes = f"{existing_notes}\n{notes_entry}".strip() if existing_notes else notes_entry
                    updated = True
            if updated:
                db.session.commit()
            sync_success, sync_detail = True, "Provisioned via /opt/user_manager.sh"
        else:
            flash(f'Stream provisioning script failed: {script_output}', 'warning')

        if not sync_success:
            sync_success, sync_detail = sync_user_with_streaming(user, 'create')
            if not sync_success:
                flash(f'Streaming server sync failed: {sync_detail}', 'warning')

        purge_success, purge_detail = purge_playlist_cache([user.token])
        if not purge_success:
            flash(f'Cloudflare cache purge failed: {purge_detail}', 'warning')

        SystemLog.log('INFO', 'USER', f'Created user: {username}', request.remote_addr)
        flash(f'User {username} created successfully!', 'success')
        return redirect(url_for('users_view', user_id=user.id))
    
    return render_template('users_add.html')

@app.route('/users/<int:user_id>')
@login_required
def users_view(user_id):
    user = User.query.get_or_404(user_id)
    
    active_conns = Connection.query.filter(
        Connection.user_id == user_id,
        Connection.last_heartbeat > datetime.utcnow() - timedelta(minutes=2)
    ).all()
    
    stream_domain = Settings.get('stream_domain', request.host)
    m3u_template = Settings.get('m3u_url_format', f"http://{stream_domain}/playlist/{{TOKEN}}.m3u8")
    m3u_url = m3u_template.replace('{TOKEN}', user.token)
    if '{CHANNEL_ID}' in m3u_url:
        m3u_url = m3u_url.replace('{CHANNEL_ID}', 'all')

    return render_template('users_view.html', user=user, active_connections=active_conns, m3u_url=m3u_url)

@app.route('/users/<int:user_id>/edit', methods=['GET', 'POST'])
@login_required
def users_edit(user_id):
    user = User.query.get_or_404(user_id)
    
    if request.method == 'POST':
        user.username = request.form.get('username')
        user.email = request.form.get('email', '')
        user.max_connections = int(request.form.get('max_connections'))
        user.is_active = request.form.get('is_active') == 'on'
        user.notes = request.form.get('notes', '')
        
        new_password = request.form.get('password')
        if new_password:
            user.password = new_password

        db.session.commit()

        sync_success, sync_detail = sync_user_with_streaming(user, 'update')
        if not sync_success:
            flash(f'Streaming server sync failed: {sync_detail}', 'warning')

        purge_success, purge_detail = purge_playlist_cache([user.token])
        if not purge_success:
            flash(f'Cloudflare cache purge failed: {purge_detail}', 'warning')

        SystemLog.log('INFO', 'USER', f'Updated user: {user.username}', request.remote_addr)
        flash('User updated successfully!', 'success')
        return redirect(url_for('users_view', user_id=user.id))
    
    return render_template('users_edit.html', user=user)

@app.route('/users/<int:user_id>/extend', methods=['POST'])
@login_required
def users_extend(user_id):
    user = User.query.get_or_404(user_id)
    days = int(request.form.get('days', 30))
    user.extend_subscription(days)
    db.session.commit()

    sync_success, sync_detail = sync_user_with_streaming(user, 'update')
    if not sync_success:
        flash(f'Streaming server sync failed: {sync_detail}', 'warning')

    purge_success, purge_detail = purge_playlist_cache([user.token])
    if not purge_success:
        flash(f'Cloudflare cache purge failed: {purge_detail}', 'warning')

    SystemLog.log('INFO', 'USER', f'Extended {user.username} by {days} days', request.remote_addr)
    flash(f'Subscription extended by {days} days', 'success')
    return redirect(url_for('users_view', user_id=user.id))

@app.route('/users/<int:user_id>/reset-token', methods=['POST'])
@login_required
def users_reset_token(user_id):
    user = User.query.get_or_404(user_id)
    old_token = user.token
    user.generate_token(get_token_length())
    db.session.commit()

    sync_success, sync_detail = sync_user_with_streaming(user, 'update')
    if not sync_success:
        flash(f'Streaming server sync failed: {sync_detail}', 'warning')

    tokens_to_purge = [user.token]
    if old_token:
        tokens_to_purge.append(old_token)
    purge_success, purge_detail = purge_playlist_cache(tokens_to_purge)
    if not purge_success:
        flash(f'Cloudflare cache purge failed: {purge_detail}', 'warning')

    SystemLog.log('INFO', 'USER', f'Reset token for {user.username}', request.remote_addr)
    flash('Token reset successfully!', 'warning')
    return redirect(url_for('users_view', user_id=user.id))

@app.route('/users/<int:user_id>/delete', methods=['POST'])
@login_required
def users_delete(user_id):
    user = User.query.get_or_404(user_id)
    username = user.username
    token = user.token

    sync_success, sync_detail = sync_user_with_streaming(user, 'delete')
    if not sync_success:
        flash(f'Streaming server sync failed: {sync_detail}', 'warning')

    purge_playlist_cache([token])

    db.session.delete(user)
    db.session.commit()

    SystemLog.log('WARNING', 'USER', f'Deleted user: {username}', request.remote_addr)
    flash(f'User {username} deleted', 'info')
    return redirect(url_for('users_list'))

# ============================================================================
# CHANNEL MANAGEMENT
# ============================================================================

@app.route('/channels')
@login_required
def channels_list():
    category = request.args.get('category', '')
    channels = Channel.query
    
    if category:
        channels = channels.filter_by(category=category)
    
    channels = channels.order_by(Channel.category, Channel.name).all()
    categories = db.session.query(Channel.category).distinct().all()
    
    return render_template('channels_list.html', channels=channels, categories=[c[0] for c in categories], selected_category=category)

@app.route('/channels/add', methods=['GET', 'POST'])
@login_required
def channels_add():
    if request.method == 'POST':
        channel_id = request.form.get('channel_id')
        name = request.form.get('name')
        category = request.form.get('category', 'General')
        source_url = request.form.get('source_url')
        logo_url = request.form.get('logo_url', '')
        quality = request.form.get('quality', 'medium')
        
        if Channel.query.filter_by(channel_id=channel_id).first():
            flash('Channel ID already exists', 'danger')
            return redirect(url_for('channels_add'))
        
        channel = Channel(
            channel_id=channel_id,
            name=name,
            category=category,
            source_url=source_url,
            logo_url=logo_url,
            quality=quality
        )
        
        db.session.add(channel)
        db.session.commit()

        sync_success, sync_detail = sync_channel_with_streaming(channel, 'create')
        if not sync_success:
            flash(f'Streaming server channel sync failed: {sync_detail}', 'warning')

        purge_success, purge_detail = purge_channel_cache(channel.channel_id)
        if not purge_success:
            flash(f'Cloudflare cache purge failed: {purge_detail}', 'warning')

        SystemLog.log('INFO', 'CHANNEL', f'Added channel: {name}', request.remote_addr)
        flash(f'Channel {name} added successfully!', 'success')
        return redirect(url_for('channels_list'))
    
    return render_template('channels_add.html')

@app.route('/channels/<int:channel_id>/delete', methods=['POST'])
@login_required
def channels_delete(channel_id):
    channel = Channel.query.get_or_404(channel_id)
    name = channel.name

    sync_success, sync_detail = sync_channel_with_streaming(channel, 'delete')
    if not sync_success:
        flash(f'Streaming server channel sync failed: {sync_detail}', 'warning')

    purge_channel_cache(channel.channel_id)

    db.session.delete(channel)
    db.session.commit()
    SystemLog.log('WARNING', 'CHANNEL', f'Deleted channel: {name}', request.remote_addr)
    flash(f'Channel {name} deleted', 'info')
    return redirect(url_for('channels_list'))

@app.route('/channels/import', methods=['GET', 'POST'])
@login_required
def channels_import():
    if request.method == 'POST':
        m3u_content = request.form.get('m3u_content', '')
        
        if not m3u_content:
            flash('Please provide M3U content', 'danger')
            return redirect(url_for('channels_import'))
        
        lines = m3u_content.split('\n')
        imported = 0
        skipped = 0
        new_channels = []
        
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            
            if line.startswith('#EXTINF'):
                name_match = re.search(r',(.+)$', line)
                name = name_match.group(1).strip() if name_match else f'Channel {i}'
                
                logo_match = re.search(r'tvg-logo="([^"]+)"', line)
                logo = logo_match.group(1) if logo_match else ''
                
                category_match = re.search(r'group-title="([^"]+)"', line)
                category = category_match.group(1) if category_match else 'Imported'
                
                if i + 1 < len(lines):
                    url = lines[i + 1].strip()
                    
                    if url and (url.startswith('http') or url.startswith('rtmp')):
                        channel_id = f'imp{1000 + imported + skipped}'
                        
                        if not Channel.query.filter_by(channel_id=channel_id).first():
                            channel = Channel(
                                channel_id=channel_id,
                                name=name,
                                source_url=url,
                                logo_url=logo,
                                category=category
                            )
                            db.session.add(channel)
                            new_channels.append(channel)
                            imported += 1
                        else:
                            skipped += 1
                
                i += 2
            else:
                i += 1
        
        db.session.commit()

        sync_failures = []
        purge_failures = []
        for imported_channel in new_channels:
            sync_success, sync_detail = sync_channel_with_streaming(imported_channel, 'create')
            if not sync_success:
                sync_failures.append(f"{imported_channel.channel_id}")

            purge_success, purge_detail = purge_channel_cache(imported_channel.channel_id)
            if not purge_success:
                purge_failures.append(f"{imported_channel.channel_id}")

        if sync_failures:
            flash(f'Streaming sync failed for channels: {", ".join(sync_failures[:5])}', 'warning')
        if purge_failures:
            flash(f'Cloudflare purge failed for channels: {", ".join(purge_failures[:5])}', 'warning')
        SystemLog.log('INFO', 'CHANNEL', f'Imported {imported} channels ({skipped} skipped)', request.remote_addr)
        flash(f'Imported {imported} channels successfully! ({skipped} skipped as duplicates)', 'success')
        return redirect(url_for('channels_list'))
    
    return render_template('channels_import.html')

# ============================================================================
# PUBLIC API
# ============================================================================

def _extract_api_token():
    """Return API token from Authorization header, custom header, or query string."""
    auth_header = request.headers.get('Authorization', '')
    if auth_header and auth_header.lower().startswith('bearer '):
        return auth_header.split(' ', 1)[1].strip()
    header_token = request.headers.get('X-Api-Token') or request.headers.get('X-API-Token')
    if header_token:
        return header_token.strip()
    return request.args.get('api_token', '').strip()

@app.route('/api/users', methods=['POST'])
def api_create_user():
    if not ADMIN_API_TOKEN:
        return jsonify({'error': 'API token not configured'}), 503
    
    provided_token = _extract_api_token()
    if not provided_token or not secrets.compare_digest(provided_token, ADMIN_API_TOKEN):
        return jsonify({'error': 'Unauthorized'}), 401
    
    payload = request.get_json(silent=True)
    if not payload:
        return jsonify({'error': 'Invalid JSON payload'}), 400
    
    username = (payload.get('username') or '').strip()
    email = (payload.get('email') or '').strip()
    notes = (payload.get('notes') or '').strip()
    password = payload.get('password') or secrets.token_urlsafe(12)
    
    try:
        days_value = payload.get('days', payload.get('expiry_days', 30))
        days = int(days_value)
        if days <= 0:
            raise ValueError
    except (TypeError, ValueError):
        return jsonify({'error': 'Invalid subscription days value'}), 400
    
    try:
        max_conn_value = payload.get('max_connections', 1)
        max_connections = int(max_conn_value)
        if max_connections <= 0:
            raise ValueError
    except (TypeError, ValueError):
        return jsonify({'error': 'Invalid max_connections value'}), 400
    
    if len(username) < 3:
        return jsonify({'error': 'Username must be at least 3 characters'}), 400
    
    if User.query.filter_by(username=username).first():
        return jsonify({'error': 'Username already exists'}), 409
    
    user = User(
        username=username,
        password=password,
        email=email,
        expiry_date=datetime.utcnow() + timedelta(days=days),
        max_connections=max_connections,
        notes=notes
    )
    user.generate_token(get_token_length())
    
    db.session.add(user)
    db.session.commit()

    script_data, script_output = create_stream_user_via_script(user.username, days)
    if not script_data or not script_data.get('token'):
        db.session.delete(user)
        db.session.commit()
        return jsonify({'error': 'Failed to provision streaming user', 'detail': script_output}), 502

    updated = False
    if script_data.get('password'):
        user.password = script_data['password']
        updated = True
    if script_data.get('token'):
        user.token = script_data['token']
        updated = True
    if script_data.get('m3u_url'):
        apply_m3u_template_from_url(script_data.get('m3u_url'), script_data.get('token'))
        notes_entry = f"M3U URL: {script_data['m3u_url']}"
        existing_notes = user.notes or ''
        if notes_entry not in existing_notes:
            user.notes = f"{existing_notes}\\n{notes_entry}".strip() if existing_notes else notes_entry
            updated = True
    if updated:
        db.session.commit()

    streaming_success, streaming_detail = True, "Provisioned via /opt/user_manager.sh"
    if not script_data:
        streaming_success, streaming_detail = sync_user_with_streaming(user, 'create')
    purge_success, purge_detail = purge_playlist_cache([user.token])

    SystemLog.log('INFO', 'API', f'Created user via API: {username}', request.remote_addr)
    
    return jsonify({
        'id': user.id,
        'username': user.username,
        'password': user.password,
        'token': user.token,
        'expires_at': user.expiry_date.isoformat(),
        'max_connections': user.max_connections,
        'email': user.email,
        'm3u_url': script_data.get('m3u_url'),
        'streaming_sync': {
            'success': streaming_success,
            'detail': streaming_detail
        },
        'cloudflare_purge': {
            'success': purge_success,
            'detail': purge_detail
        }
    }), 201

@app.route('/api/auth/<token>')
def api_auth(token):
    user = User.query.filter_by(token=token).first()
    
    if not user:
        return jsonify({'error': 'Invalid token', 'authorized': False}), 401
    
    if not user.is_active:
        return jsonify({'error': 'Account disabled', 'authorized': False}), 403
    
    if user.is_expired():
        return jsonify({'error': 'Subscription expired', 'authorized': False}), 403
    
    active_conns = Connection.query.filter(
        Connection.user_id == user.id,
        Connection.last_heartbeat > datetime.utcnow() - timedelta(minutes=2)
    ).count()
    
    if active_conns >= user.max_connections:
        return jsonify({'error': 'Connection limit reached', 'authorized': False}), 429
    
    user.last_access = datetime.utcnow()
    db.session.commit()
    
    return jsonify({
        'authorized': True,
        'username': user.username,
        'expiry': user.expiry_date.isoformat(),
        'max_connections': user.max_connections
    })

@app.route('/api/connection', methods=['POST'])
def api_connection():
    data = request.json or {}
    token = data.get('token')
    channel_id = data.get('channel_id')
    
    user = User.query.filter_by(token=token).first()
    if not user:
        return jsonify({'error': 'Invalid token'}), 401
    
    conn = Connection.query.filter_by(
        user_id=user.id,
        ip_address=request.remote_addr,
        channel_id=channel_id
    ).first()
    
    if not conn:
        conn = Connection(
            user_id=user.id,
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent', '')[:255],
            channel_id=channel_id
        )
        db.session.add(conn)
    else:
        conn.last_heartbeat = datetime.utcnow()
    
    db.session.commit()
    return jsonify({'status': 'ok'})

@app.route('/playlist/<token>.m3u8')
def generate_playlist(token):
    user = User.query.filter_by(token=token).first()
    
    if not user or not user.is_active or user.is_expired():
        abort(403)
    
    channels = Channel.query.filter_by(is_active=True).order_by(Channel.category, Channel.name).all()
    stream_domain = Settings.get('stream_domain', request.host)
    format_template = Settings.get('m3u_url_format', f"http://{stream_domain}/live/stream_{{CHANNEL_ID}}.m3u8?token={{TOKEN}}")

    m3u = "#EXTM3U\n"

    for channel in channels:
        m3u += f'#EXTINF:-1 tvg-id="{channel.channel_id}" tvg-name="{channel.name}" '
        if channel.logo_url:
            m3u += f'tvg-logo="{channel.logo_url}" '
        m3u += f'group-title="{channel.category}",{channel.name}\n'
        stream_url = format_template.replace('{CHANNEL_ID}', channel.channel_id).replace('{TOKEN}', token)
        stream_url = stream_url.replace('{channel_id}', channel.channel_id).replace('{token}', token)
        m3u += f'{stream_url}\n'
    
    user.last_access = datetime.utcnow()
    db.session.commit()
    
    return m3u, 200, {'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8'}

# ============================================================================
# SYSTEM
# ============================================================================

@app.route('/settings', methods=['GET', 'POST'])
@login_required
def settings():
    if request.method == 'POST':
        Settings.set('stream_domain', request.form.get('stream_domain', ''))
        Settings.set('stream_server_ip', request.form.get('stream_server_ip', ''))
        Settings.set('default_expiry_days', request.form.get('default_expiry_days', '30'))
        Settings.set('default_max_connections', request.form.get('default_max_connections', '2'))
        flash('Settings saved successfully!', 'success')
        return redirect(url_for('settings'))
    
    return render_template('settings.html')

@app.route('/logs')
@login_required
def logs():
    page = request.args.get('page', 1, type=int)
    level = request.args.get('level', '')
    category = request.args.get('category', '')
    
    query = SystemLog.query
    
    if level:
        query = query.filter_by(level=level)
    if category:
        query = query.filter_by(category=category)
    
    logs = query.order_by(SystemLog.timestamp.desc()).paginate(page=page, per_page=50)
    
    return render_template('logs.html', logs=logs, level=level, category=category)

@app.route('/api/stats')
@login_required
def api_stats():
    return jsonify({
        'total_users': User.query.count(),
        'active_users': User.query.filter(User.is_active == True, User.expiry_date > datetime.utcnow()).count(),
        'total_channels': Channel.query.filter_by(is_active=True).count(),
        'active_connections': Connection.query.filter(
            Connection.last_heartbeat > datetime.utcnow() - timedelta(minutes=2)
        ).count()
    })

# ============================================================================
# INITIALIZATION
# ============================================================================

def init_db():
    with app.app_context():
        db.create_all()
        
        if not Admin.query.filter_by(username='admin').first():
            admin = Admin(username='admin', email='admin@localhost')
            admin.set_password(os.environ.get('ADMIN_PASSWORD', 'admin123'))
            db.session.add(admin)
            db.session.commit()
            print("✓ Created default admin")
        
        if not Settings.query.get('stream_domain'):
            Settings.set('stream_domain', os.environ.get('STREAM_DOMAIN', 'stream.yourdomain.com'))
            Settings.set('stream_server_ip', os.environ.get('STREAM_SERVER_IP', '0.0.0.0'))
            Settings.set('default_expiry_days', '30')
            Settings.set('default_max_connections', '2')
            Settings.set('token_length', Settings.get('token_length', '64'))
            Settings.set('setup_complete', Settings.get('setup_complete', 'false'))
            print("✓ Created default settings")

        if Settings.get('setup_complete') is None:
            Settings.set('setup_complete', 'false')

if __name__ == '__main__':
    init_db()
    app.run(host='0.0.0.0', port=5000, debug=True)

EOFAPP

echo -e "${YELLOW}[4/12] Creating requirements.txt...${NC}"
cat > requirements.txt << 'EOF'
Flask==3.0.0
Flask-SQLAlchemy==3.1.1
Flask-Login==0.6.3
Flask-WTF==1.2.1
Werkzeug==3.0.1
bcrypt==4.1.2
PyJWT==2.8.0
python-dotenv==1.0.0
Flask-Migrate==4.0.5
requests==2.31.0
redis==5.0.1
gunicorn==21.2.0
psutil==5.9.6
psycopg2-binary==2.9.9
EOF

echo -e "${YELLOW}[5/12] Creating .env configuration...${NC}"
cat > .env << ENVEOF
SECRET_KEY=$(openssl rand -hex 32)
DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/${POSTGRES_DB}
STREAM_DOMAIN=$STREAM_DOMAIN
STREAM_SERVER_IP=$STREAM_IP
ADMIN_PASSWORD=$ADMIN_PASS
ADMIN_API_TOKEN=$(openssl rand -hex 32)
STREAMING_API_BASE_URL=$STREAMING_API_BASE_URL
STREAMING_API_TOKEN=$STREAMING_API_TOKEN
STREAMING_API_TIMEOUT=$STREAMING_API_TIMEOUT
CLOUDFLARE_ZONE_ID=$CLOUDFLARE_ZONE_ID
CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN
POSTGRES_DB=$POSTGRES_DB
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
ENVEOF

################################################################################
# HTML TEMPLATES
################################################################################

echo -e "${YELLOW}[6/12] Creating HTML templates...${NC}"

# Base template
cat > templates/base.html << 'EOFHTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport"="width=device-width, initial-scale=1.0">
    <title>{% block title %}IPTV Panel{% endblock %}</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
</head>
<body>
    {% if current_user.is_authenticated %}
    <nav class="navbar navbar-expand-lg navbar-dark bg-dark">
        <div class="container-fluid">
            <a class="navbar-brand" href="{{ url_for('dashboard') }}">
                <i class="bi bi-broadcast"></i> IPTV Panel
            </a>
            <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNav">
                <span class="navbar-toggler-icon"></span>
            </button>
            <div class="collapse navbar-collapse" id="navbarNav">
                <ul class="navbar-nav">
                    <li class="nav-item">
                        <a class="nav-link" href="{{ url_for('dashboard') }}">
                            <i class="bi bi-speedometer2"></i> Dashboard
                        </a>
                    </li>
                    <li class="nav-item">
                        <a class="nav-link" href="{{ url_for('users_list') }}">
                            <i class="bi bi-people"></i> Users
                        </a>
                    </li>
                    <li class="nav-item">
                        <a class="nav-link" href="{{ url_for('channels_list') }}">
                            <i class="bi bi-tv"></i> Channels
                        </a>
                    </li>
                    <li class="nav-item">
                        <a class="nav-link" href="{{ url_for('settings') }}">
                            <i class="bi bi-gear"></i> Settings
                        </a>
                    </li>
                    <li class="nav-item">
                        <a class="nav-link" href="{{ url_for('logs') }}">
                            <i class="bi bi-journal-text"></i> Logs
                        </a>
                    </li>
                </ul>
                <ul class="navbar-nav ms-auto">
                    <li class="nav-item">
                        <span class="navbar-text me-3">
                            <i class="bi bi-person-circle"></i> {{ current_user.username }}
                        </span>
                    </li>
                    <li class="nav-item">
                        <a class="nav-link" href="{{ url_for('logout') }}">
                            <i class="bi bi-box-arrow-right"></i> Logout
                        </a>
                    </li>
                </ul>
            </div>
        </div>
    </nav>
    {% endif %}

    <div class="container-fluid mt-4">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                <div class="alert alert-{{ category }} alert-dismissible fade show" role="alert">
                    {{ message }}
                    <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
                </div>
                {% endfor %}
            {% endif %}
        {% endwith %}

        {% block content %}{% endblock %}
    </div>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    <script src="{{ url_for('static', filename='js/main.js') }}"></script>
    {% block scripts %}{% endblock %}
</body>
</html>
EOFHTML

cat > templates/setup_wizard.html << 'EOFWIZ'
{% extends "base.html" %}
{% block title %}Initial Setup - IPTV Panel{% endblock %}
{% block content %}
<div class="row justify-content-center">
    <div class="col-lg-8">
        <div class="card shadow-sm">
            <div class="card-header bg-primary text-white">
                <h4 class="mb-0"><i class="bi bi-sliders"></i> Initial Setup Wizard</h4>
                <small>Step {{ step }} of 3</small>
            </div>
            <div class="card-body">
                {% if step == 1 %}
                <form method="POST">
                    <div class="mb-3">
                        <label class="form-label">Server Name</label>
                        <input type="text" class="form-control" name="server_name" value="{{ server_name }}" required>
                        <small class="text-muted">Used across the panel (e.g., dashboard header).</small>
                    </div>
                    <div class="mb-3">
                        <label class="form-label">Time Zone</label>
                        <input type="text" class="form-control" name="timezone" value="{{ timezone }}" placeholder="UTC">
                    </div>
                    <div class="mb-3">
                        <label class="form-label">Language</label>
                        <input type="text" class="form-control" name="language" value="{{ language }}" placeholder="English">
                    </div>
                    <div class="d-flex justify-content-end">
                        <button type="submit" class="btn btn-primary">Continue</button>
                    </div>
                </form>
                {% elif step == 2 %}
                <form method="POST">
                    <div class="row">
                        <div class="col-md-6 mb-3">
                            <label class="form-label">Server Name</label>
                            <input type="text" class="form-control" name="stream_server_name" value="{{ streaming_config.get('name', 'Hetzner-Stream-01') }}" required>
                        </div>
                        <div class="col-md-6 mb-3">
                            <label class="form-label">Server IP</label>
                            <input type="text" class="form-control" name="stream_server_ip" value="{{ streaming_config.get('ip', '') }}" required>
                        </div>
                    </div>
                    <div class="row">
                        <div class="col-md-4 mb-3">
                            <label class="form-label">Server Port</label>
                            <input type="text" class="form-control" name="stream_server_port" value="{{ streaming_config.get('port', '80') }}">
                        </div>
                        <div class="col-md-4 mb-3">
                            <label class="form-label">Server Type</label>
                            <input type="text" class="form-control" name="stream_server_type" value="{{ streaming_config.get('type', 'Load Balancer') }}">
                        </div>
                        <div class="col-md-4 mb-3">
                            <label class="form-label">Protocol</label>
                            <input type="text" class="form-control" name="stream_server_protocol" value="{{ streaming_config.get('protocol', 'HTTP') }}">
                        </div>
                    </div>
                    <div class="mb-3">
                        <label class="form-label">Status</label>
                        <select class="form-select" name="stream_server_status">
                            {% set status = streaming_config.get('status', 'Active') %}
                            <option value="Active" {% if status == 'Active' %}selected{% endif %}>Active</option>
                            <option value="Maintenance" {% if status == 'Maintenance' %}selected{% endif %}>Maintenance</option>
                            <option value="Disabled" {% if status == 'Disabled' %}selected{% endif %}>Disabled</option>
                        </select>
                    </div>
                    <div class="d-flex justify-content-between">
                        <a href="{{ url_for('setup_wizard', step=1) }}" class="btn btn-secondary">Back</a>
                        <button type="submit" class="btn btn-primary">Continue</button>
                    </div>
                </form>
                {% elif step == 3 %}
                <form method="POST">
                    <div class="mb-3">
                        <label class="form-label">M3U URL Format</label>
                        <input type="text" class="form-control" name="m3u_url_format" value="{{ m3u_url_format }}" required>
                        <small class="text-muted">Use placeholders {CHANNEL_ID} and {TOKEN}. Example: http://stream.myiptv.com/live/stream_{CHANNEL_ID}.m3u8?token={TOKEN}</small>
                    </div>
                    <div class="row">
                        <div class="col-md-6 mb-3">
                            <label class="form-label">Token Type</label>
                            <select class="form-select" name="token_type">
                                <option value="user" {% if token_type == 'user' %}selected{% endif %}>User Token</option>
                                <option value="channel" {% if token_type == 'channel' %}selected{% endif %}>Channel Token</option>
                            </select>
                        </div>
                        <div class="col-md-6 mb-3">
                            <label class="form-label">Token Length (characters)</label>
                            <input type="number" class="form-control" name="token_length" value="{{ token_length }}" min="16" step="2">
                        </div>
                    </div>
                    <div class="d-flex justify-content-between">
                        <a href="{{ url_for('setup_wizard', step=2) }}" class="btn btn-secondary">Back</a>
                        <button type="submit" class="btn btn-success">Finish &amp; Launch Panel</button>
                    </div>
                </form>
                {% endif %}
            </div>
        </div>
    </div>
</div>
{% endblock %}

EOFWIZ

# Login template
cat > templates/login.html << 'EOFHTML'
{% extends "base.html" %}

{% block title %}Login - IPTV Panel{% endblock %}

{% block content %}
<div class="row justify-content-center mt-5">
    <div class="col-md-4">
        <div class="card shadow">
            <div class="card-body">
                <h3 class="card-title text-center mb-4">
                    <i class="bi bi-broadcast"></i> IPTV Panel
                </h3>
                <form method="POST">
                    <div class="mb-3">
                        <label class="form-label">Username</label>
                        <input type="text" name="username" class="form-control" required autofocus>
                    </div>
                    <div class="mb-3">
                        <label class="form-label">Password</label>
                        <input type="password" name="password" class="form-control" required>
                    </div>
                    <button type="submit" class="btn btn-primary w-100">
                        <i class="bi bi-box-arrow-in-right"></i> Login
                    </button>
                </form>
            </div>
        </div>
    </div>
</div>
{% endblock %}
EOFHTML

# Dashboard template
cat > templates/dashboard.html << 'EOFHTML'
{% extends "base.html" %}

{% block title %}Dashboard - IPTV Panel{% endblock %}

{% block content %}
<h2 class="mb-4"><i class="bi bi-speedometer2"></i> Dashboard</h2>

<div class="row">
    <div class="col-md-3">
        <div class="card bg-primary text-white">
            <div class="card-body">
                <h5>Total Users</h5>
                <h2>{{ total_users }}</h2>
            </div>
        </div>
    </div>
    <div class="col-md-3">
        <div class="card bg-success text-white">
            <div class="card-body">
                <h5>Active Users</h5>
                <h2>{{ active_users }}</h2>
            </div>
        </div>
    </div>
    <div class="col-md-3">
        <div class="card bg-warning text-white">
            <div class="card-body">
                <h5>Active Connections</h5>
                <h2>{{ active_connections }}</h2>
            </div>
        </div>
    </div>
    <div class="col-md-3">
        <div class="card bg-info text-white">
            <div class="card-body">
                <h5>Total Channels</h5>
                <h2>{{ total_channels }}</h2>
            </div>
        </div>
    </div>
</div>

<div class="row mt-4">
    <div class="col-md-6">
        <div class="card">
            <div class="card-header">
                <h5><i class="bi bi-people"></i> Recent Users</h5>
            </div>
            <div class="card-body">
                <table class="table">
                    <thead>
                        <tr>
                            <th>Username</th>
                            <th>Status</th>
                            <th>Expires</th>
                        </tr>
                    </thead>
                    <tbody>
                        {% for user in recent_users %}
                        <tr>
                            <td>
                                <a href="{{ url_for('users_view', user_id=user.id) }}">{{ user.username }}</a>
                            </td>
                            <td>
                                {% if user.is_expired() %}
                                <span class="badge bg-danger">Expired</span>
                                {% elif user.is_active %}
                                <span class="badge bg-success">Active</span>
                                {% else %}
                                <span class="badge bg-secondary">Disabled</span>
                                {% endif %}
                            </td>
                            <td>{{ user.expiry_date.strftime('%Y-%m-%d') }}</td>
                        </tr>
                        {% endfor %}
                    </tbody>
                </table>
            </div>
        </div>
    </div>
    
    <div class="col-md-6">
        <div class="card">
            <div class="card-header">
                <h5><i class="bi bi-exclamation-triangle"></i> Expiring Soon</h5>
            </div>
            <div class="card-body">
                {% if expiring_soon %}
                <table class="table">
                    <thead>
                        <tr>
                            <th>Username</th>
                            <th>Days Left</th>
                            <th>Action</th>
                        </tr>
                    </thead>
                    <tbody>
                        {% for user in expiring_soon %}
                        <tr>
                            <td>{{ user.username }}</td>
                            <td><span class="badge bg-warning">{{ user.days_remaining() }} days</span></td>
                            <td>
                                <a href="{{ url_for('users_view', user_id=user.id) }}" class="btn btn-sm btn-primary">
                                    <i class="bi bi-eye"></i>
                                </a>
                            </td>
                        </tr>
                        {% endfor %}
                    </tbody>
                </table>
                {% else %}
                <p class="text-muted">No users expiring in the next 7 days</p>
                {% endif %}
            </div>
        </div>
    </div>
</div>

<div class="row mt-4">
    <div class="col-md-12">
        <div class="card">
            <div class="card-header">
                <h5><i class="bi bi-journal-text"></i> Recent Activity</h5>
            </div>
            <div class="card-body">
                <table class="table">
                    <thead>
                        <tr>
                            <th>Time</th>
                            <th>Level</th>
                            <th>Category</th>
                            <th>Message</th>
                        </tr>
                    </thead>
                    <tbody>
                        {% for log in recent_logs %}
                        <tr>
                            <td>{{ log.timestamp.strftime('%Y-%m-%d %H:%M:%S') }}</td>
                            <td>
                                {% if log.level == 'ERROR' %}
                                <span class="badge bg-danger">{{ log.level }}</span>
                                {% elif log.level == 'WARNING' %}
                                <span class="badge bg-warning">{{ log.level }}</span>
                                {% else %}
                                <span class="badge bg-info">{{ log.level }}</span>
                                {% endif %}
                            </td>
                            <td>{{ log.category }}</td>
                            <td>{{ log.message }}</td>
                        </tr>
                        {% endfor %}
                    </tbody>
                </table>
            </div>
        </div>
    </div>
</div>
{% endblock %}
EOFHTML

# Users list template  
cat > templates/users_list.html << 'EOFHTML'
{% extends "base.html" %}

{% block title %}Users - IPTV Panel{% endblock %}

{% block content %}
<div class="d-flex justify-content-between align-items-center mb-4">
    <h2><i class="bi bi-people"></i> Users</h2>
    <a href="{{ url_for('users_add') }}" class="btn btn-primary">
        <i class="bi bi-plus-circle"></i> Add User
    </a>
</div>

<div class="card mb-3">
    <div class="card-body">
        <form method="GET" class="row g-3">
            <div class="col-md-4">
                <input type="text" name="search" class="form-control" placeholder="Search..." value="{{ search }}">
            </div>
            <div class="col-md-3">
                <select name="status" class="form-select">
                    <option value="all" {% if status == 'all' %}selected{% endif %}>All Status</option>
                    <option value="active" {% if status == 'active' %}selected{% endif %}>Active</option>
                    <option value="expired" {% if status == 'expired' %}selected{% endif %}>Expired</option>
                    <option value="disabled" {% if status == 'disabled' %}selected{% endif %}>Disabled</option>
                </select>
            </div>
            <div class="col-md-2">
                <button type="submit" class="btn btn-primary w-100">
                    <i class="bi bi-search"></i> Filter
                </button>
            </div>
        </form>
    </div>
</div>

<div class="card">
    <div class="card-body">
        <table class="table table-hover">
            <thead>
                <tr>
                    <th>Username</th>
                    <th>Email</th>
                    <th>Status</th>
                    <th>Expiry</th>
                    <th>Max Connections</th>
                    <th>Created</th>
                    <th>Actions</th>
                </tr>
            </thead>
            <tbody>
                {% for user in users.items %}
                <tr>
                    <td><strong>{{ user.username }}</strong></td>
                    <td>{{ user.email or '-' }}</td>
                    <td>
                        {% if user.is_expired() %}
                        <span class="badge bg-danger">Expired</span>
                        {% elif user.is_active %}
                        <span class="badge bg-success">Active</span>
                        {% else %}
                        <span class="badge bg-secondary">Disabled</span>
                        {% endif %}
                    </td>
                    <td>
                        {{ user.expiry_date.strftime('%Y-%m-%d') }}
                        <br>
                        <small class="text-muted">{{ user.days_remaining() }} days left</small>
                    </td>
                    <td>{{ user.max_connections }}</td>
                    <td>{{ user.created_at.strftime('%Y-%m-%d') }}</td>
                    <td>
                        <a href="{{ url_for('users_view', user_id=user.id) }}" class="btn btn-sm btn-info">
                            <i class="bi bi-eye"></i>
                        </a>
                        <a href="{{ url_for('users_edit', user_id=user.id) }}" class="btn btn-sm btn-warning">
                            <i class="bi bi-pencil"></i>
                        </a>
                    </td>
                </tr>
                {% endfor %}
            </tbody>
        </table>
        
        {% if users.pages > 1 %}
        <nav>
            <ul class="pagination">
                {% if users.has_prev %}
                <li class="page-item">
                    <a class="page-link" href="{{ url_for('users_list', page=users.prev_num, search=search, status=status) }}">Previous</a>
                </li>
                {% endif %}
                
                {% for page_num in users.iter_pages(left_edge=1, right_edge=1, left_current=1, right_current=2) %}
                    {% if page_num %}
                        <li class="page-item {% if page_num == users.page %}active{% endif %}">
                            <a class="page-link" href="{{ url_for('users_list', page=page_num, search=search, status=status) }}">{{ page_num }}</a>
                        </li>
                    {% else %}
                        <li class="page-item disabled"><span class="page-link">...</span></li>
                    {% endif %}
                {% endfor %}
                
                {% if users.has_next %}
                <li class="page-item">
                    <a class="page-link" href="{{ url_for('users_list', page=users.next_num, search=search, status=status) }}">Next</a>
                </li>
                {% endif %}
            </ul>
        </nav>
        {% endif %}
    </div>
</div>
{% endblock %}
EOFHTML

# User add template
cat > templates/users_add.html << 'EOFHTML'
{% extends "base.html" %}

{% block title %}Add User - IPTV Panel{% endblock %}

{% block content %}
<h2 class="mb-4"><i class="bi bi-person-plus"></i> Add New User</h2>

<div class="card">
    <div class="card-body">
        <form method="POST">
            <div class="row">
                <div class="col-md-6">
                    <div class="mb-3">
                        <label class="form-label">Username *</label>
                        <input type="text" name="username" class="form-control" required>
                    </div>
                </div>
                <div class="col-md-6">
                    <div class="mb-3">
                        <label class="form-label">Password (auto-generated if empty)</label>
                        <input type="text" name="password" class="form-control">
                    </div>
                </div>
            </div>
            
            <div class="row">
                <div class="col-md-6">
                    <div class="mb-3">
                        <label class="form-label">Email</label>
                        <input type="email" name="email" class="form-control">
                    </div>
                </div>
                <div class="col-md-3">
                    <div class="mb-3">
                        <label class="form-label">Subscription Days *</label>
                        <input type="number" name="days" class="form-control" value="30" required>
                    </div>
                </div>
                <div class="col-md-3">
                    <div class="mb-3">
                        <label class="form-label">Max Connections *</label>
                        <input type="number" name="max_connections" class="form-control" value="1" required>
                    </div>
                </div>
            </div>
            
            <div class="mb-3">
                <label class="form-label">Notes</label>
                <textarea name="notes" class="form-control" rows="3"></textarea>
            </div>
            
            <div class="d-flex gap-2">
                <button type="submit" class="btn btn-primary">
                    <i class="bi bi-check-circle"></i> Create User
                </button>
                <a href="{{ url_for('users_list') }}" class="btn btn-secondary">
                    <i class="bi bi-x-circle"></i> Cancel
                </a>
            </div>
        </form>
    </div>
</div>
{% endblock %}
EOFHTML

# User view template
cat > templates/users_view.html << 'EOFHTML'
{% extends "base.html" %}

{% block title %}{{ user.username }} - IPTV Panel{% endblock %}

{% block content %}
<div class="d-flex justify-content-between align-items-center mb-4">
    <h2><i class="bi bi-person-circle"></i> {{ user.username }}</h2>
    <div>
        <a href="{{ url_for('users_edit', user_id=user.id) }}" class="btn btn-warning">
            <i class="bi bi-pencil"></i> Edit
        </a>
        <form method="POST" action="{{ url_for('users_delete', user_id=user.id) }}" style="display:inline;" onsubmit="return confirm('Delete this user?');">
            <button type="submit" class="btn btn-danger">
                <i class="bi bi-trash"></i> Delete
            </button>
        </form>
    </div>
</div>

<div class="row">
    <div class="col-md-6">
        <div class="card mb-3">
            <div class="card-header">
                <h5><i class="bi bi-info-circle"></i> User Information</h5>
            </div>
            <div class="card-body">
                <table class="table table-bordered">
                    <tr>
                        <th>Username</th>
                        <td>{{ user.username }}</td>
                    </tr>
                    <tr>
                        <th>Password</th>
                        <td><code>{{ user.password }}</code></td>
                    </tr>
                    <tr>
                        <th>Email</th>
                        <td>{{ user.email or '-' }}</td>
                    </tr>
                    <tr>
                        <th>Status</th>
                        <td>
                            {% if user.is_expired() %}
                            <span class="badge bg-danger">Expired</span>
                            {% elif user.is_active %}
                            <span class="badge bg-success">Active</span>
                            {% else %}
                            <span class="badge bg-secondary">Disabled</span>
                            {% endif %}
                        </td>
                    </tr>
                    <tr>
                        <th>Expiry Date</th>
                        <td>
                            {{ user.expiry_date.strftime('%Y-%m-%d %H:%M:%S') }}
                            <br>
                            <small class="text-muted">{{ user.days_remaining() }} days remaining</small>
                        </td>
                    </tr>
                    <tr>
                        <th>Max Connections</th>
                        <td>{{ user.max_connections }}</td>
                    </tr>
                    <tr>
                        <th>Created</th>
                        <td>{{ user.created_at.strftime('%Y-%m-%d %H:%M:%S') }}</td>
                    </tr>
                    <tr>
                        <th>Last Access</th>
                        <td>{{ user.last_access.strftime('%Y-%m-%d %H:%M:%S') if user.last_access else 'Never' }}</td>
                    </tr>
                </table>
                
                <form method="POST" action="{{ url_for('users_extend', user_id=user.id) }}" class="mt-3">
                    <label class="form-label">Extend Subscription</label>
                    <div class="input-group">
                        <input type="number" name="days" class="form-control" value="30" required>
                        <button type="submit" class="btn btn-primary">
                            <i class="bi bi-calendar-plus"></i> Extend
                        </button>
                    </div>
                </form>
            </div>
        </div>
    </div>
    
    <div class="col-md-6">
        <div class="card mb-3">
            <div class="card-header">
                <h5><i class="bi bi-link-45deg"></i> M3U Playlist</h5>
            </div>
            <div class="card-body">
                <div class="mb-3">
                    <label class="form-label">Token</label>
                    <div class="input-group">
                        <input type="text" class="form-control" value="{{ user.token }}" readonly>
                        <button class="btn btn-outline-secondary" onclick="navigator.clipboard.writeText('{{ user.token }}')">
                            <i class="bi bi-clipboard"></i>
                        </button>
                    </div>
                </div>
                
                <div class="mb-3">
                    <label class="form-label">M3U URL</label>
                    <div class="input-group">
                        <input type="text" class="form-control" value="{{ m3u_url }}" readonly>
                        <button class="btn btn-outline-secondary" onclick="navigator.clipboard.writeText('{{ m3u_url }}')">
                            <i class="bi bi-clipboard"></i>
                        </button>
                    </div>
                </div>
                
                <form method="POST" action="{{ url_for('users_reset_token', user_id=user.id) }}" onsubmit="return confirm('Reset token? This will invalidate old M3U links!');">
                    <button type="submit" class="btn btn-warning w-100">
                        <i class="bi bi-arrow-clockwise"></i> Reset Token
                    </button>
                </form>
            </div>
        </div>
        
        <div class="card">
            <div class="card-header">
                <h5><i class="bi bi-plug"></i> Active Connections ({{ active_connections|length }})</h5>
            </div>
            <div class="card-body">
                {% if active_connections %}
                <table class="table table-sm">
                    <thead>
                        <tr>
                            <th>IP</th>
                            <th>Channel</th>
                            <th>Started</th>
                        </tr>
                    </thead>
                    <tbody>
                        {% for conn in active_connections %}
                        <tr>
                            <td>{{ conn.ip_address }}</td>
                            <td>{{ conn.channel_id }}</td>
                            <td>{{ conn.connected_at.strftime('%H:%M:%S') }}</td>
                        </tr>
                        {% endfor %}
                    </tbody>
                </table>
                {% else %}
                <p class="text-muted">No active connections</p>
                {% endif %}
            </div>
        </div>
    </div>
</div>

{% if user.notes %}
<div class="card mt-3">
    <div class="card-header">
        <h5><i class="bi bi-sticky"></i> Notes</h5>
    </div>
    <div class="card-body">
        <p>{{ user.notes }}</p>
    </div>
</div>
{% endif %}
{% endblock %}
EOFHTML

# User edit template
cat > templates/users_edit.html << 'EOFHTML'
{% extends "base.html" %}

{% block title %}Edit {{ user.username }} - IPTV Panel{% endblock %}

{% block content %}
<h2 class="mb-4"><i class="bi bi-pencil"></i> Edit User: {{ user.username }}</h2>

<div class="card">
    <div class="card-body">
        <form method="POST">
            <div class="row">
                <div class="col-md-6">
                    <div class="mb-3">
                        <label class="form-label">Username *</label>
                        <input type="text" name="username" class="form-control" value="{{ user.username }}" required>
                    </div>
                </div>
                <div class="col-md-6">
                    <div class="mb-3">
                        <label class="form-label">New Password (leave empty to keep current)</label>
                        <input type="text" name="password" class="form-control">
                    </div>
                </div>
            </div>
            
            <div class="row">
                <div class="col-md-6">
                    <div class="mb-3">
                        <label class="form-label">Email</label>
                        <input type="email" name="email" class="form-control" value="{{ user.email or '' }}">
                    </div>
                </div>
                <div class="col-md-6">
                    <div class="mb-3">
                        <label class="form-label">Max Connections *</label>
                        <input type="number" name="max_connections" class="form-control" value="{{ user.max_connections }}" required>
                    </div>
                </div>
            </div>
            
            <div class="mb-3">
                <div class="form-check">
                    <input class="form-check-input" type="checkbox" name="is_active" id="is_active" {% if user.is_active %}checked{% endif %}>
                    <label class="form-check-label" for="is_active">
                        Account Active
                    </label>
                </div>
            </div>
            
            <div class="mb-3">
                <label class="form-label">Notes</label>
                <textarea name="notes" class="form-control" rows="3">{{ user.notes or '' }}</textarea>
            </div>
            
            <div class="d-flex gap-2">
                <button type="submit" class="btn btn-primary">
                    <i class="bi bi-check-circle"></i> Save Changes
                </button>
                <a href="{{ url_for('users_view', user_id=user.id) }}" class="btn btn-secondary">
                    <i class="bi bi-x-circle"></i> Cancel
                </a>
            </div>
        </form>
    </div>
</div>
{% endblock %}
EOFHTML

# Continue with remaining templates...
# Due to length, I'll create the remaining critical templates

# Channels list
cat > templates/channels_list.html << 'EOFHTML'
{% extends "base.html" %}
{% block title %}Channels - IPTV Panel{% endblock %}
{% block content %}
<div class="d-flex justify-content-between align-items-center mb-4">
    <h2><i class="bi bi-tv"></i> Channels</h2>
    <div>
        <a href="{{ url_for('channels_add') }}" class="btn btn-primary">
            <i class="bi bi-plus-circle"></i> Add Channel
        </a>
        <a href="{{ url_for('channels_import') }}" class="btn btn-success">
            <i class="bi bi-file-earmark-arrow-up"></i> Import M3U
        </a>
    </div>
</div>

<div class="card mb-3">
    <div class="card-body">
        <form method="GET">
            <div class="row">
                <div class="col-md-4">
                    <select name="category" class="form-select" onchange="this.form.submit()">
                        <option value="">All Categories</option>
                        {% for cat in categories %}
                        <option value="{{ cat }}" {% if cat == selected_category %}selected{% endif %}>{{ cat }}</option>
                        {% endfor %}
                    </select>
                </div>
            </div>
        </form>
    </div>
</div>

<div class="card">
    <div class="card-body">
        <table class="table table-hover">
            <thead>
                <tr>
                    <th>ID</th>
                    <th>Name</th>
                    <th>Category</th>
                    <th>Status</th>
                    <th>Views</th>
                    <th>Actions</th>
                </tr>
            </thead>
            <tbody>
                {% for channel in channels %}
                <tr>
                    <td><code>{{ channel.channel_id }}</code></td>
                    <td>
                        {% if channel.logo_url %}
                        <img src="{{ channel.logo_url }}" style="height:30px;" class="me-2">
                        {% endif %}
                        {{ channel.name }}
                    </td>
                    <td><span class="badge bg-secondary">{{ channel.category }}</span></td>
                    <td>
                        {% if channel.is_active %}
                        <span class="badge bg-success">Active</span>
                        {% else %}
                        <span class="badge bg-danger">Inactive</span>
                        {% endif %}
                    </td>
                    <td>{{ channel.view_count }}</td>
                    <td>
                        <form method="POST" action="{{ url_for('channels_delete', channel_id=channel.id) }}" style="display:inline;" onsubmit="return confirm('Delete?');">
                            <button type="submit" class="btn btn-sm btn-danger">
                                <i class="bi bi-trash"></i>
                            </button>
                        </form>
                    </td>
                </tr>
                {% endfor %}
            </tbody>
        </table>
    </div>
</div>
{% endblock %}
EOFHTML

# Channels add
cat > templates/channels_add.html << 'EOFHTML'
{% extends "base.html" %}
{% block title %}Add Channel - IPTV Panel{% endblock %}
{% block content %}
<h2 class="mb-4"><i class="bi bi-tv"></i> Add New Channel</h2>
<div class="card">
    <div class="card-body">
        <form method="POST">
            <div class="row">
                <div class="col-md-6">
                    <div class="mb-3">
                        <label class="form-label">Channel ID *</label>
                        <input type="text" name="channel_id" class="form-control" required>
                    </div>
                </div>
                <div class="col-md-6">
                    <div class="mb-3">
                        <label class="form-label">Channel Name *</label>
                        <input type="text" name="name" class="form-control" required>
                    </div>
                </div>
            </div>
            <div class="row">
                <div class="col-md-6">
                    <div class="mb-3">
                        <label class="form-label">Category</label>
                        <input type="text" name="category" class="form-control" value="General">
                    </div>
                </div>
                <div class="col-md-6">
                    <div class="mb-3">
                        <label class="form-label">Quality</label>
                        <select name="quality" class="form-select">
                            <option value="low">Low (1 Mbps)</option>
                            <option value="medium" selected>Medium (1.5 Mbps)</option>
                            <option value="high">High (2.5 Mbps)</option>
                        </select>
                    </div>
                </div>
            </div>
            <div class="mb-3">
                <label class="form-label">Source URL *</label>
                <input type="url" name="source_url" class="form-control" required>
            </div>
            <div class="mb-3">
                <label class="form-label">Logo URL</label>
                <input type="url" name="logo_url" class="form-control">
            </div>
            <div class="d-flex gap-2">
                <button type="submit" class="btn btn-primary">
                    <i class="bi bi-check-circle"></i> Add Channel
                </button>
                <a href="{{ url_for('channels_list') }}" class="btn btn-secondary">
                    <i class="bi bi-x-circle"></i> Cancel
                </a>
            </div>
        </form>
    </div>
</div>
{% endblock %}
EOFHTML

# Channels import
cat > templates/channels_import.html << 'EOFHTML'
{% extends "base.html" %}
{% block title %}Import Channels - IPTV Panel{% endblock %}
{% block content %}
<h2 class="mb-4"><i class="bi bi-file-earmark-arrow-up"></i> Import Channels from M3U</h2>
<div class="card">
    <div class="card-body">
        <form method="POST">
            <div class="mb-3">
                <label class="form-label">Paste M3U Content</label>
                <textarea name="m3u_content" class="form-control" rows="15" placeholder="#EXTM3U&#10;#EXTINF:-1,Channel Name&#10;http://source.com/stream.m3u8" required></textarea>
                <small class="text-muted">Paste your complete M3U playlist here</small>
            </div>
            <div class="d-flex gap-2">
                <button type="submit" class="btn btn-success">
                    <i class="bi bi-upload"></i> Import Channels
                </button>
                <a href="{{ url_for('channels_list') }}" class="btn btn-secondary">
                    <i class="bi bi-x-circle"></i> Cancel
                </a>
            </div>
        </form>
    </div>
</div>
{% endblock %}
EOFHTML

# Settings template
cat > templates/settings.html << 'EOFHTML'
{% extends "base.html" %}
{% block title %}Settings - IPTV Panel{% endblock %}
{% block content %}
<h2 class="mb-4"><i class="bi bi-gear"></i> System Settings</h2>
<div class="card">
    <div class="card-body">
        <form method="POST">
            <div class="mb-3">
                <label class="form-label">Streaming Server Domain</label>
                <input type="text" name="stream_domain" class="form-control" 
                       value="{{ Settings.get('stream_domain', 'stream.yourdomain.com') }}">
                <small class="text-muted">Domain where streams are served</small>
            </div>
            <div class="mb-3">
                <label class="form-label">Streaming Server IP</label>
                <input type="text" name="stream_server_ip" class="form-control" 
                       value="{{ Settings.get('stream_server_ip', '0.0.0.0') }}">
            </div>
            <div class="row">
                <div class="col-md-6">
                    <div class="mb-3">
                        <label class="form-label">Default Subscription Days</label>
                        <input type="number" name="default_expiry_days" class="form-control" 
                               value="{{ Settings.get('default_expiry_days', '30') }}">
                    </div>
                </div>
                <div class="col-md-6">
                    <div class="mb-3">
                        <label class="form-label">Default Max Connections</label>
                        <input type="number" name="default_max_connections" class="form-control" 
                               value="{{ Settings.get('default_max_connections', '2') }}">
                    </div>
                </div>
            </div>
            <button type="submit" class="btn btn-primary">
                <i class="bi bi-check-circle"></i> Save Settings
            </button>
        </form>
    </div>
</div>
{% endblock %}
EOFHTML

# Logs template
cat > templates/logs.html << 'EOFHTML'
{% extends "base.html" %}
{% block title %}System Logs - IPTV Panel{% endblock %}
{% block content %}
<h2 class="mb-4"><i class="bi bi-journal-text"></i> System Logs</h2>
<div class="card mb-3">
    <div class="card-body">
        <form method="GET" class="row g-3">
            <div class="col-md-3">
                <select name="level" class="form-select" onchange="this.form.submit()">
                    <option value="">All Levels</option>
                    <option value="INFO" {% if level == 'INFO' %}selected{% endif %}>INFO</option>
                    <option value="WARNING" {% if level == 'WARNING' %}selected{% endif %}>WARNING</option>
                    <option value="ERROR" {% if level == 'ERROR' %}selected{% endif %}>ERROR</option>
                </select>
            </div>
            <div class="col-md-3">
                <select name="category" class="form-select" onchange="this.form.submit()">
                    <option value="">All Categories</option>
                    <option value="AUTH" {% if category == 'AUTH' %}selected{% endif %}>AUTH</option>
                    <option value="USER" {% if category == 'USER' %}selected{% endif %}>USER</option>
                    <option value="CHANNEL" {% if category == 'CHANNEL' %}selected{% endif %}>CHANNEL</option>
                    <option value="SYSTEM" {% if category == 'SYSTEM' %}selected{% endif %}>SYSTEM</option>
                </select>
            </div>
        </form>
    </div>
</div>
<div class="card">
    <div class="card-body">
        <table class="table table-sm">
            <thead>
                <tr>
                    <th>Time</th>
                    <th>Level</th>
                    <th>Category</th>
                    <th>Message</th>
                    <th>IP</th>
                </tr>
            </thead>
            <tbody>
                {% for log in logs.items %}
                <tr>
                    <td>{{ log.timestamp.strftime('%Y-%m-%d %H:%M:%S') }}</td>
                    <td>
                        {% if log.level == 'ERROR' %}
                        <span class="badge bg-danger">{{ log.level }}</span>
                        {% elif log.level == 'WARNING' %}
                        <span class="badge bg-warning">{{ log.level }}</span>
                        {% else %}
                        <span class="badge bg-info">{{ log.level }}</span>
                        {% endif %}
                    </td>
                    <td><span class="badge bg-secondary">{{ log.category }}</span></td>
                    <td>{{ log.message }}</td>
                    <td><small>{{ log.ip_address or '-' }}</small></td>
                </tr>
                {% endfor %}
            </tbody>
        </table>
        {% if logs.pages > 1 %}
        <nav>
            <ul class="pagination">
                {% if logs.has_prev %}
                <li class="page-item"><a class="page-link" href="{{ url_for('logs', page=logs.prev_num, level=level, category=category) }}">Previous</a></li>
                {% endif %}
                {% for page_num in logs.iter_pages(left_edge=1, right_edge=1) %}
                    {% if page_num %}
                    <li class="page-item {% if page_num == logs.page %}active{% endif %}">
                        <a class="page-link" href="{{ url_for('logs', page=page_num, level=level, category=category) }}">{{ page_num }}</a>
                    </li>
                    {% else %}
                    <li class="page-item disabled"><span class="page-link">...</span></li>
                    {% endif %}
                {% endfor %}
                {% if logs.has_next %}
                <li class="page-item"><a class="page-link" href="{{ url_for('logs', page=logs.next_num, level=level, category=category) }}">Next</a></li>
                {% endif %}
            </ul>
        </nav>
        {% endif %}
    </div>
</div>
{% endblock %}
EOFHTML

################################################################################
# STATIC FILES
################################################################################

echo -e "${YELLOW}[7/12] Creating CSS stylesheet...${NC}"
cat > static/css/style.css << 'EOFCSS'
/* IPTV Panel Custom Styles */
:root {
    --primary-color: #0d6efd;
    --secondary-color: #6c757d;
    --success-color: #198754;
    --danger-color: #dc3545;
    --warning-color: #ffc107;
}

body {
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    background-color: #f8f9fa;
}

.navbar-brand {
    font-weight: bold;
    font-size: 1.3rem;
}

.card {
    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    border: none;
    margin-bottom: 20px;
}

.table-hover tbody tr:hover {
    background-color: #f8f9fa;
}

.badge {
    padding: 0.4em 0.6em;
}

.btn {
    border-radius: 0.25rem;
}

.form-control:focus, .form-select:focus {
    border-color: var(--primary-color);
    box-shadow: 0 0 0 0.2rem rgba(13, 110, 253, 0.25);
}

code {
    background-color: #f8f9fa;
    padding: 2px 6px;
    border-radius: 3px;
    color: #d63384;
}

.alert {
    border-radius: 0.25rem;
}

/* Dashboard cards */
.card.bg-primary, .card.bg-success, .card.bg-warning, .card.bg-info {
    border: none;
}

/* Pagination */
.pagination {
    margin-top: 20px;
}

/* Responsive table */
@media (max-width: 768px) {
    .table {
        font-size: 0.875rem;
    }
}
EOFCSS

echo -e "${YELLOW}[8/12] Creating JavaScript...${NC}"
cat > static/js/main.js << 'EOFJS'
// IPTV Panel JavaScript

// Auto-dismiss alerts after 5 seconds
document.addEventListener('DOMContentLoaded', function() {
    const alerts = document.querySelectorAll('.alert');
    alerts.forEach(function(alert) {
        setTimeout(function() {
            const bsAlert = new bootstrap.Alert(alert);
            bsAlert.close();
        }, 5000);
    });
});

// Copy to clipboard function
function copyToClipboard(text) {
    navigator.clipboard.writeText(text).then(function() {
        alert('Copied to clipboard!');
    }).catch(function(err) {
        console.error('Failed to copy:', err);
    });
}

// Confirm delete actions
document.querySelectorAll('form[onsubmit*="confirm"]').forEach(function(form) {
    form.addEventListener('submit', function(e) {
        if (!confirm('Are you sure?')) {
            e.preventDefault();
        }
    });
});

// Auto-refresh dashboard stats every 30 seconds
if (window.location.pathname === '/') {
    setInterval(function() {
        fetch('/api/stats')
            .then(response => response.json())
            .then(data => {
                // Update dashboard stats if elements exist
                const elements = {
                    total_users: document.querySelector('.card.bg-primary h2'),
                    active_users: document.querySelector('.card.bg-success h2'),
                    active_connections: document.querySelector('.card.bg-warning h2'),
                    total_channels: document.querySelector('.card.bg-info h2')
                };
                
                if (elements.total_users) elements.total_users.textContent = data.total_users;
                if (elements.active_users) elements.active_users.textContent = data.active_users;
                if (elements.active_connections) elements.active_connections.textContent = data.active_connections;
                if (elements.total_channels) elements.total_channels.textContent = data.total_channels;
            })
            .catch(err => console.error('Stats refresh failed:', err));
    }, 30000);
}
EOFJS

################################################################################
# CONFIG FILES
################################################################################

echo -e "${YELLOW}[9/12] Skipping initial Nginx configuration...${NC}"

echo -e "${YELLOW}[10/12] Creating systemd service template...${NC}"
cat > config/iptv-panel.service << EOFUNIT
[Unit]
Description=IPTV Panel Gunicorn Service
After=network.target postgresql.service

[Service]
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${INSTALL_DIR}/venv/bin/gunicorn -w 4 -b 127.0.0.1:5000 --timeout 120 app:app
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOFUNIT

################################################################################
# UTILITY SCRIPTS
################################################################################

echo -e "${YELLOW}[11/12] Creating utility scripts...${NC}"

cat > scripts/backup.sh << 'EOFBACKUP'
#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$BASE_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "Environment file not found: $ENV_FILE" >&2
    exit 1
fi

BACKUP_DIR="$BASE_DIR/backups"
DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_DIR"

export PGPASSWORD="${POSTGRES_PASSWORD}"
pg_dump -U "$POSTGRES_USER" -h localhost -Fc "$POSTGRES_DB" > "$BACKUP_DIR/backup_${DATE}.dump"
find "$BACKUP_DIR" -name "backup_*.dump" -mtime +7 -delete
echo "Backup completed: backup_${DATE}.dump"
EOFBACKUP

cat > scripts/restore.sh << 'EOFRESTORE'
#!/bin/bash
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: ./restore.sh <backup_file.dump>" >&2
    exit 1
fi

BACKUP_FILE="$1"
if [ ! -f "$BACKUP_FILE" ]; then
    echo "Backup file not found: $BACKUP_FILE" >&2
    exit 1
fi

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$BASE_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "Environment file not found: $ENV_FILE" >&2
    exit 1
fi

export PGPASSWORD="${POSTGRES_PASSWORD}"
pg_restore -U "$POSTGRES_USER" -h localhost -d "$POSTGRES_DB" --clean --if-exists "$BACKUP_FILE"
systemctl restart iptv-panel
echo "Database restored from $BACKUP_FILE"
EOFRESTORE

chmod +x scripts/*.sh

################################################################################
# FINALIZATION
################################################################################

echo -e "${YELLOW}[12/12] Finalizing installation...${NC}"

chown -R "$APP_USER:$APP_GROUP" "$INSTALL_DIR"
chmod 640 "$INSTALL_DIR/.env"

runuser -l "$APP_USER" -c "cd '$INSTALL_DIR' && python3 -m venv venv"
runuser -l "$APP_USER" -c "cd '$INSTALL_DIR' && venv/bin/pip install --upgrade pip wheel setuptools"
runuser -l "$APP_USER" -c "cd '$INSTALL_DIR' && venv/bin/pip install -r requirements.txt"
runuser -l "$APP_USER" -c "cd '$INSTALL_DIR' && venv/bin/python -c 'from app import init_db; init_db(); print(\"✓ Database initialized\")'"

cat > /etc/systemd/system/iptv-panel.service << EOFDEPLOY
[Unit]
Description=IPTV Panel Gunicorn Service
After=network.target postgresql.service

[Service]
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${INSTALL_DIR}/venv/bin/gunicorn -w 4 -b 127.0.0.1:5000 --timeout 120 app:app
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOFDEPLOY

chmod 644 /etc/systemd/system/iptv-panel.service

systemctl daemon-reload
systemctl enable iptv-panel
systemctl restart iptv-panel

echo "Nginx configuration will be handled by deploy.sh"

echo ""
echo -e "${GREEN}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                                                            ║"
echo "║           INSTALLATION COMPLETE!                           ║"
echo "║                                                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo -e "${BLUE}Installation Details:${NC}"
echo "  Location: $INSTALL_DIR"
echo "  Panel Domain: $STREAM_DOMAIN"
echo "  Streaming Server IP: $STREAM_IP"
echo "  PostgreSQL DB: $POSTGRES_DB (user: $POSTGRES_USER)"
echo ""
echo -e "${BLUE}Service Status:${NC}"
echo "  Application service: iptv-panel (systemctl status iptv-panel)"

echo ""
echo -e "${BLUE}Credentials:${NC}"
echo "  Admin login: admin"
echo "  Admin password: $ADMIN_PASS"
echo ""
echo -e "${YELLOW}Operational Notes:${NC}"
echo "  Environment file: $INSTALL_DIR/.env (permissions 640)"
echo "  Backup script: $INSTALL_DIR/scripts/backup.sh"
echo "  Restore script: $INSTALL_DIR/scripts/restore.sh"
echo "  Logs: $INSTALL_DIR/logs/"

echo ""
echo -e "${GREEN}Installation log saved to: $INSTALL_DIR/installation.log${NC}"
echo ""

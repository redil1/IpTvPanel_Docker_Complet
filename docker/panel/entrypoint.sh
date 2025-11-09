#!/bin/sh
#
# IPTV Panel Docker Entrypoint
#
# This script is responsible for:
# 1. Waiting for the PostgreSQL database to be ready.
# 2. Running Flask database migrations.
# 3. Executing the main container command (Gunicorn).

set -e

# --- Configuration ---
# Database connection details are passed via environment variables
DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-iptv_admin}"
DB_NAME="${DB_NAME:-iptv_panel}"
# The PGPASSWORD is used by psql to connect without a password prompt
export PGPASSWORD="${DB_PASS}"

# --- Wait for Database ---
echo "Entrypoint: Waiting for database at ${DB_HOST}:${DB_PORT} to be ready..."

# Timeout after 30 seconds
counter=0
while ! psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c '\q' > /dev/null 2>&1; do
    counter=$((counter + 1))
    if [ $counter -ge 60 ]; then
        echo "Entrypoint: ERROR - Database is not available after 120 seconds. Exiting."
        exit 1
    fi
    echo "Entrypoint: Database not ready. Retrying in 2 seconds..."
    sleep 2
done

echo "Entrypoint: Database is ready."

# --- Run Migrations ---
echo "Entrypoint: Running database migrations..."
export FLASK_APP=app.py
flask db upgrade

echo "Entrypoint: Database migrations complete."

# --- Initialize DB (if needed) ---
# This command creates the default admin user and settings on first run.
# It's safe to run multiple times.
echo "Entrypoint: Initializing application (creating default admin/settings if needed)..."
python -c "from app import init_db; init_db()"

echo "Entrypoint: Initialization complete."

# --- Sync runtime settings from environment ---
python - <<'PY'
import os
from app import app
from database.models import Settings

stream_domain = os.environ.get("STREAM_DOMAIN", "").strip()
stream_server_ip = os.environ.get("STREAM_SERVER_IP", "").strip()
channel_template = os.environ.get("M3U_URL_TEMPLATE", "").strip()
playlist_template = os.environ.get("STREAMING_PLAYLIST_TEMPLATE", "").strip()
panel_domain = os.environ.get("PANEL_DOMAIN", "").strip()

with app.app_context():
    if stream_domain:
        Settings.set("stream_domain", stream_domain)
    if stream_server_ip:
        Settings.set("stream_server_ip", stream_server_ip)

    default_channel_template = None
    if stream_domain:
        default_channel_template = f"https://{stream_domain}/live/stream/{{CHANNEL_ID}}.m3u8?token={{TOKEN}}"
    else:
        default_channel_template = "https://stream.local/live/stream/{CHANNEL_ID}.m3u8?token={TOKEN}"

    template_to_use = channel_template or default_channel_template
    if template_to_use:
        Settings.set("m3u_url_format", template_to_use)

    if not playlist_template and stream_domain:
        playlist_template = f"https://{stream_domain}/get_playlist.php?token={{TOKEN}}"
    if playlist_template:
        Settings.set("stream_playlist_format", playlist_template)

    if panel_domain:
        Settings.set("panel_domain", panel_domain)

    # Ensure basic defaults exist
    Settings.set("default_expiry_days", Settings.get("default_expiry_days", "30") or "30")
    Settings.set("default_max_connections", Settings.get("default_max_connections", "2") or "2")
    Settings.set("token_length", Settings.get("token_length", "64") or "64")

print("Entrypoint: Stream settings synchronized from environment.")
PY

# --- Migrate Orphan Channels to Default Source (M3U Multi-Source Support) ---
echo "Entrypoint: Checking for orphan channels (legacy channels without M3U source)..."
python - <<'PY'
from app import app, db
from database.models import Channel, M3USource

with app.app_context():
    # Check if there are any channels without a source
    orphan_channels = Channel.query.filter_by(source_id=None).all()

    if orphan_channels:
        print(f"Entrypoint: Found {len(orphan_channels)} orphan channels. Creating default source...")

        # Check if default source already exists
        default_source = M3USource.query.filter_by(name='Default Source (Legacy)').first()

        if not default_source:
            # Create a default source
            default_source = M3USource(
                name='Default Source (Legacy)',
                is_active=True,
                total_channels=len(orphan_channels),
                detected_attributes='[]',
                field_mapping='{}',
                description='Auto-created source for existing channels during migration'
            )
            db.session.add(default_source)
            db.session.flush()

        # Link all orphan channels to this source
        for channel in orphan_channels:
            channel.source_id = default_source.id

        # Update channel count
        default_source.total_channels = Channel.query.filter_by(source_id=default_source.id).count()

        db.session.commit()
        print(f"Entrypoint: ✓ Migrated {len(orphan_channels)} channels to default source")
    else:
        print("Entrypoint: ✓ No orphan channels found. All channels have sources.")
PY

echo "Entrypoint: Migration complete."

# --- Execute Main Command ---
# The CMD from the Dockerfile will be executed now.
echo "Entrypoint: Starting Gunicorn server..."
exec "$@"

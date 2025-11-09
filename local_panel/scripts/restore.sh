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

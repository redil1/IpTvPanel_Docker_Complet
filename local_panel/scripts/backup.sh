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

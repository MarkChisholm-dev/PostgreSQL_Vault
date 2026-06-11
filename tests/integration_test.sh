#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT

BACKUP_DIR="$WORK_DIR/backups"
LOG_DIR="$WORK_DIR/logs"
LOCK_FILE="$WORK_DIR/postgresql_backup.lock"
CONFIG_FILE_PATH="$WORK_DIR/pg_backup.conf"

mkdir -p "$BACKUP_DIR" "$LOG_DIR"

cat > "$CONFIG_FILE_PATH" << EOF
BACKUP_DIR="$BACKUP_DIR"
LOG_DIR="$LOG_DIR"
LOG_FILE="${LOG_DIR}/postgresql_backup.log"
LOCK_FILE="$LOCK_FILE"
BACKUP_RETENTION_DAYS=14

DATABASES=(
  "postgres"
)

PGHOST="127.0.0.1"
PGPORT="5432"
PGUSER="postgres"
PGDATABASE=""
PGSERVICE=""

ENABLE_CHECKSUMS=true
ENCRYPTION_MODE="none"
EOF

export CONFIG_FILE="$CONFIG_FILE_PATH"
export PGPASSWORD="postgres"

bash "$ROOT_DIR/script.sh"

backup_count="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.sql.gz' | wc -l | tr -d ' ')"
checksum_count="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.sha256' | wc -l | tr -d ' ')"

if [[ "$backup_count" -lt 1 ]]; then
  echo "Expected at least one .sql.gz backup artifact, found $backup_count"
  exit 1
fi

if [[ "$checksum_count" -lt 1 ]]; then
  echo "Expected at least one .sha256 checksum artifact, found $checksum_count"
  exit 1
fi

if ! grep -q "status=SUCCESS" "$LOG_DIR/postgresql_backup.log"; then
  echo "Expected success status in log file"
  exit 1
fi

echo "Integration test passed: backup artifact, checksum, and success log all present."

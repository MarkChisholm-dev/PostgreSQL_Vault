#!/usr/bin/env bash

# Automated PostgreSQL backup script for Linux enterprise environments.
# Compatible with Bash 5+.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

###############################################################################
# Configuration (can be overridden by external config file)
###############################################################################

# Optional external configuration file. Set CONFIG_FILE env var to override.
CONFIG_FILE="${CONFIG_FILE:-/etc/postgresql/pg_backup.conf}"

# Base directory where compressed backup files are stored.
BACKUP_DIR="/var/backups/postgresql"

# Directory for script log files.
LOG_DIR="/var/log/postgresql-backup"

# Dedicated log file for this script.
LOG_FILE="${LOG_DIR}/postgresql_backup.log"

# Number of days to keep backup files before automatic deletion.
BACKUP_RETENTION_DAYS=14

# Optional SHA-256 checksum generation and verification for backup files.
ENABLE_CHECKSUMS=true
SHA256SUM_BIN="sha256sum"

# Optional backup encryption settings.
# ENCRYPTION_MODE supports: none, age, gpg
ENCRYPTION_MODE="none"

# AGE encryption settings (used when ENCRYPTION_MODE=age).
# Example: AGE_RECIPIENTS=("age1..." "age1...")
AGE_BIN="age"
AGE_RECIPIENTS=()

# GPG encryption settings (used when ENCRYPTION_MODE=gpg).
# Example: GPG_RECIPIENTS=("backup@example.com")
GPG_BIN="gpg"
GPG_RECIPIENTS=()
GPG_OPTS=("--batch" "--yes" "--trust-model" "always")

# File lock to prevent concurrent script execution.
LOCK_FILE="/var/lock/postgresql_backup.lock"

# List of databases to back up. External config may replace this array.
DATABASES=(
  "postgres"
)

# PostgreSQL connection parameters.
# Keep credentials out of this script; use .pgpass, PGSERVICE, or env injection.
PGHOST="localhost"
PGPORT="5432"
PGUSER="postgres"
PGDATABASE=""
PGSERVICE=""

# Additional pg_dump options tuned for consistent, portable logical backups.
PG_DUMP_OPTS=(
  "--format=plain"
  "--single-transaction"
  "--no-owner"
  "--no-privileges"
  "--encoding=UTF8"
)

# Tool paths/commands (override if needed).
PG_DUMP_BIN="pg_dump"
GZIP_BIN="gzip"
FIND_BIN="find"
FLOCK_BIN="flock"

# Conservative PATH for cron/systemd contexts.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

###############################################################################
# External configuration override
###############################################################################

if [[ -r "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

###############################################################################
# Logging and utility helpers
###############################################################################

timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

log_msg() {
  # Format: timestamp db=<name> status=<STATE> msg=<detail>
  local db_name="$1"
  local status="$2"
  local message="$3"
  printf "%s db=%s status=%s msg=%s\n" "$(timestamp)" "$db_name" "$status" "$message" >> "$LOG_FILE"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" > /dev/null 2>&1; then
    printf "%s\n" "Required command not found: $cmd" >&2
    exit 127
  fi
}

###############################################################################
# Runtime state, cleanup, and trap handlers
###############################################################################

current_db=""
current_backup_file=""
current_checksum_file=""
current_encrypted_file=""

cleanup_partial_backup() {
  # Remove partially created backup files after failures.
  if [[ -n "$current_backup_file" && -f "$current_backup_file" ]]; then
    rm -f -- "$current_backup_file"
    log_msg "${current_db:-N/A}" "FAILURE" "Removed partial file: $current_backup_file"
  fi

  if [[ -n "$current_checksum_file" && -f "$current_checksum_file" ]]; then
    rm -f -- "$current_checksum_file"
    log_msg "${current_db:-N/A}" "FAILURE" "Removed partial checksum file: $current_checksum_file"
  fi

  if [[ -n "$current_encrypted_file" && -f "$current_encrypted_file" ]]; then
    rm -f -- "$current_encrypted_file"
    log_msg "${current_db:-N/A}" "FAILURE" "Removed partial encrypted file: $current_encrypted_file"
  fi
}

on_error() {
  local exit_code=$?
  local line_no="$1"
  local cmd="${BASH_COMMAND:-unknown}"

  log_msg "${current_db:-N/A}" "FAILURE" "Unhandled error at line $line_no; command='$cmd'; exit_code=$exit_code"
  cleanup_partial_backup
  exit "$exit_code"
}

on_exit() {
  local exit_code=$?
  if ((exit_code != 0)); then
    cleanup_partial_backup
  fi
}

trap 'on_error "$LINENO"' ERR
trap on_exit EXIT

###############################################################################
# Initialization and lock acquisition
###############################################################################

initialize_environment() {
  mkdir -p -- "$BACKUP_DIR" "$LOG_DIR" "$(dirname -- "$LOCK_FILE")"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"

  require_cmd "$PG_DUMP_BIN"
  require_cmd "$GZIP_BIN"
  require_cmd "$FIND_BIN"
  require_cmd "$FLOCK_BIN"
  require_cmd "date"

  if [[ "$ENABLE_CHECKSUMS" == "true" ]]; then
    require_cmd "$SHA256SUM_BIN"
  fi

  case "$ENCRYPTION_MODE" in
    none) ;;
    age)
      require_cmd "$AGE_BIN"
      if ((${#AGE_RECIPIENTS[@]} == 0)); then
        log_msg "N/A" "FAILURE" "ENCRYPTION_MODE=age but AGE_RECIPIENTS is empty"
        exit 3
      fi
      ;;
    gpg)
      require_cmd "$GPG_BIN"
      if ((${#GPG_RECIPIENTS[@]} == 0)); then
        log_msg "N/A" "FAILURE" "ENCRYPTION_MODE=gpg but GPG_RECIPIENTS is empty"
        exit 3
      fi
      ;;
    *)
      log_msg "N/A" "FAILURE" "Invalid ENCRYPTION_MODE: $ENCRYPTION_MODE"
      exit 3
      ;;
  esac

  if ((${#DATABASES[@]} == 0)); then
    log_msg "N/A" "FAILURE" "DATABASES array is empty; nothing to back up"
    exit 2
  fi

  # Export connection environment variables only when provided.
  [[ -n "$PGHOST" ]] && export PGHOST
  [[ -n "$PGPORT" ]] && export PGPORT
  [[ -n "$PGUSER" ]] && export PGUSER
  [[ -n "$PGDATABASE" ]] && export PGDATABASE
  [[ -n "$PGSERVICE" ]] && export PGSERVICE

  # Open lock file on FD 200 and acquire a non-blocking exclusive lock.
  exec 200> "$LOCK_FILE"
  if ! "$FLOCK_BIN" -n 200; then
    log_msg "N/A" "FAILURE" "Another backup process is already running"
    exit 10
  fi
}

###############################################################################
# Backup and retention logic
###############################################################################

backup_database() {
  local db_name="$1"
  local safe_db_name
  local output_file
  local backup_ts
  local final_file

  current_db="$db_name"
  backup_ts="$(date "+%Y-%m-%d_%H-%M-%S")"

  # Sanitize database name for filesystem safety while retaining recognizable name.
  safe_db_name="${db_name//[^a-zA-Z0-9_.-]/_}"
  output_file="${BACKUP_DIR}/${safe_db_name}_${backup_ts}.sql.gz"
  current_backup_file="$output_file"
  current_checksum_file=""
  current_encrypted_file=""
  final_file="$output_file"

  log_msg "$db_name" "START" "Backup started"

  # pg_dump writes SQL to stdout; gzip compresses to target file.
  # pipefail ensures pipeline failure is detected correctly.
  if "$PG_DUMP_BIN" "${PG_DUMP_OPTS[@]}" --dbname="$db_name" 2>> "$LOG_FILE" | "$GZIP_BIN" -c > "$output_file"; then
    if [[ ! -f "$output_file" || ! -s "$output_file" ]]; then
      log_msg "$db_name" "FAILURE" "Compressed backup is missing or empty: $output_file"
      cleanup_partial_backup
      current_backup_file=""
      current_checksum_file=""
      current_encrypted_file=""
      current_db=""
      return 1
    fi

    case "$ENCRYPTION_MODE" in
      none) ;;
      age)
        current_encrypted_file="${output_file}.age"
        local age_args=()
        local recipient
        for recipient in "${AGE_RECIPIENTS[@]}"; do
          age_args+=("-r" "$recipient")
        done
        if ! "$AGE_BIN" -o "$current_encrypted_file" "${age_args[@]}" "$output_file" 2>> "$LOG_FILE"; then
          log_msg "$db_name" "FAILURE" "AGE encryption failed for: $output_file"
          cleanup_partial_backup
          current_backup_file=""
          current_checksum_file=""
          current_encrypted_file=""
          current_db=""
          return 1
        fi

        if [[ ! -f "$current_encrypted_file" || ! -s "$current_encrypted_file" ]]; then
          log_msg "$db_name" "FAILURE" "Encrypted file is missing or empty: $current_encrypted_file"
          cleanup_partial_backup
          current_backup_file=""
          current_checksum_file=""
          current_encrypted_file=""
          current_db=""
          return 1
        fi

        rm -f -- "$output_file"
        current_backup_file=""
        final_file="$current_encrypted_file"
        ;;
      gpg)
        current_encrypted_file="${output_file}.gpg"
        local gpg_args=()
        local gpg_recipient
        for gpg_recipient in "${GPG_RECIPIENTS[@]}"; do
          gpg_args+=("--recipient" "$gpg_recipient")
        done
        if ! "$GPG_BIN" "${GPG_OPTS[@]}" --encrypt "${gpg_args[@]}" --output "$current_encrypted_file" "$output_file" 2>> "$LOG_FILE"; then
          log_msg "$db_name" "FAILURE" "GPG encryption failed for: $output_file"
          cleanup_partial_backup
          current_backup_file=""
          current_checksum_file=""
          current_encrypted_file=""
          current_db=""
          return 1
        fi

        if [[ ! -f "$current_encrypted_file" || ! -s "$current_encrypted_file" ]]; then
          log_msg "$db_name" "FAILURE" "Encrypted file is missing or empty: $current_encrypted_file"
          cleanup_partial_backup
          current_backup_file=""
          current_checksum_file=""
          current_encrypted_file=""
          current_db=""
          return 1
        fi

        rm -f -- "$output_file"
        current_backup_file=""
        final_file="$current_encrypted_file"
        ;;
    esac

    if [[ "$ENABLE_CHECKSUMS" == "true" ]]; then
      current_checksum_file="${final_file}.sha256"
      if ! "$SHA256SUM_BIN" "$final_file" > "$current_checksum_file" 2>> "$LOG_FILE"; then
        log_msg "$db_name" "FAILURE" "Failed to generate checksum: $current_checksum_file"
        cleanup_partial_backup
        current_backup_file=""
        current_checksum_file=""
        current_encrypted_file=""
        current_db=""
        return 1
      fi

      if ! "$SHA256SUM_BIN" --check --status "$current_checksum_file" 2>> "$LOG_FILE"; then
        log_msg "$db_name" "FAILURE" "Checksum verification failed for: $final_file"
        cleanup_partial_backup
        current_backup_file=""
        current_checksum_file=""
        current_encrypted_file=""
        current_db=""
        return 1
      fi
    fi

    log_msg "$db_name" "SUCCESS" "Backup completed: $final_file"
    current_backup_file=""
    current_checksum_file=""
    current_encrypted_file=""
    current_db=""
    return 0

  else
    local rc=$?
    log_msg "$db_name" "FAILURE" "pg_dump/gzip pipeline failed with exit code $rc"
  fi

  cleanup_partial_backup
  current_backup_file=""
  current_checksum_file=""
  current_encrypted_file=""
  current_db=""
  return 1
}

prune_old_backups() {
  local deleted_count=0
  local file_path

  # Delete files older than retention threshold.
  while IFS= read -r -d '' file_path; do
    rm -f -- "$file_path"
    deleted_count=$((deleted_count + 1))
  done < <("$FIND_BIN" "$BACKUP_DIR" -maxdepth 1 -type f \( -name "*.sql.gz" -o -name "*.sql.gz.age" -o -name "*.sql.gz.gpg" -o -name "*.sha256" \) -mtime "+$BACKUP_RETENTION_DAYS" -print0)

  log_msg "N/A" "SUCCESS" "Retention cleanup removed $deleted_count file(s) older than $BACKUP_RETENTION_DAYS day(s)"
}

###############################################################################
# Main execution flow
###############################################################################

main() {
  local overall_rc=0
  local db_name

  initialize_environment
  log_msg "N/A" "START" "Backup job started"

  for db_name in "${DATABASES[@]}"; do
    if ! backup_database "$db_name"; then
      overall_rc=1
    fi
  done

  prune_old_backups

  if ((overall_rc == 0)); then
    log_msg "N/A" "SUCCESS" "Backup job completed successfully"
  else
    log_msg "N/A" "FAILURE" "Backup job completed with one or more database failures"
  fi

  return "$overall_rc"
}

main "$@"

#!/usr/bin/env bash
# Run a long-running import with optional ALTER SYSTEM tuning, index creation, and revert.
# Usage: run as current user from repo root. Logs to ./import_release.log by default.

set -euo pipefail

RELEASE_BIN=./target/release/discogs-load
RELEASE_BUILD_CMD=(cargo build --release --bin discogs-load)
RELEASE_FILE="./discogs_20260501_releases.xml.gz"
DB_HOST=localhost
DB_PORT=5432
DB_USER=dev
DB_PASS=dev_pass
DB_NAME=discogs
BATCH_SIZE=50000
CREATE_INDEXES_AFTER_IMPORT=yes

LOG_FILE=import_release.log
PID_FILE=import.pid

echo "Import started at $(date)" > "$LOG_FILE"

change_applied=no
old_sync=""
old_maint=""

cleanup() {
  revert_alter_system
}

trap cleanup EXIT

try_alter_system() {
  echo "Attempting ALTER SYSTEM tuning (requires superuser)..." >> "$LOG_FILE"
  # Try as postgres first
  if old_sync=$(psql -h "$DB_HOST" -U postgres -d postgres -At -c "SHOW synchronous_commit;" 2>>"$LOG_FILE"); then
    old_maint=$(psql -h "$DB_HOST" -U postgres -d postgres -At -c "SHOW maintenance_work_mem;" 2>>"$LOG_FILE") || true
    echo "Current synchronous_commit=$old_sync maintenance_work_mem=$old_maint" >> "$LOG_FILE"
    psql -h "$DB_HOST" -U postgres -d postgres -c "ALTER SYSTEM SET synchronous_commit = 'off';" >>"$LOG_FILE" 2>&1
    psql -h "$DB_HOST" -U postgres -d postgres -c "ALTER SYSTEM SET maintenance_work_mem = '1GB';" >>"$LOG_FILE" 2>&1
    psql -h "$DB_HOST" -U postgres -d postgres -c "SELECT pg_reload_conf();" >>"$LOG_FILE" 2>&1
    change_applied=yes
    return 0
  fi

  # Fallback: try as provided DB_USER (may be superuser)
  if old_sync=$(PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -At -c "SHOW synchronous_commit;" 2>>"$LOG_FILE"); then
    old_maint=$(PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -At -c "SHOW maintenance_work_mem;" 2>>"$LOG_FILE") || true
    echo "Current synchronous_commit=$old_sync maintenance_work_mem=$old_maint (as $DB_USER)" >> "$LOG_FILE"
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c "ALTER SYSTEM SET synchronous_commit = 'off';" >>"$LOG_FILE" 2>&1
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c "ALTER SYSTEM SET maintenance_work_mem = '1GB';" >>"$LOG_FILE" 2>&1
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c "SELECT pg_reload_conf();" >>"$LOG_FILE" 2>&1
    change_applied=yes
    return 0
  fi

  echo "ALTER SYSTEM not applied: no superuser access available. Continuing without sys-tune." >> "$LOG_FILE"
  return 1
}

revert_alter_system() {
  if [ "$change_applied" = yes ]; then
    echo "Reverting ALTER SYSTEM to previous values..." >> "$LOG_FILE"
    if [ -n "$old_sync" ]; then
      if psql -h "$DB_HOST" -U postgres -d postgres -c "ALTER SYSTEM SET synchronous_commit = '$old_sync';" >>"$LOG_FILE" 2>&1; then
        true
      else
        PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c "ALTER SYSTEM SET synchronous_commit = '$old_sync';" >>"$LOG_FILE" 2>&1 || true
      fi
    fi
    if [ -n "$old_maint" ]; then
      if psql -h "$DB_HOST" -U postgres -d postgres -c "ALTER SYSTEM SET maintenance_work_mem = '$old_maint';" >>"$LOG_FILE" 2>&1; then
        true
      else
        PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c "ALTER SYSTEM SET maintenance_work_mem = '$old_maint';" >>"$LOG_FILE" 2>&1 || true
      fi
    fi
    # reload
    if ! psql -h "$DB_HOST" -U postgres -d postgres -c "SELECT pg_reload_conf();" >>"$LOG_FILE" 2>&1; then
      PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c "SELECT pg_reload_conf();" >>"$LOG_FILE" 2>&1 || true
    fi
    echo "Revert complete." >> "$LOG_FILE"
  else
    echo "No ALTER SYSTEM changes to revert." >> "$LOG_FILE"
  fi
}

main() {
  # Attempt to apply ALTER SYSTEM tuning
  try_alter_system || true

  # Build release binary
  echo "Building release binary..." >> "$LOG_FILE"
  "${RELEASE_BUILD_CMD[@]}" >>"$LOG_FILE" 2>&1

  if [ ! -x "$RELEASE_BIN" ]; then
    echo "Release binary not found at $RELEASE_BIN" >> "$LOG_FILE"
    exit 1
  fi

  # Start importer in background with nohup
  echo "Starting importer at $(date)" >> "$LOG_FILE"
  # Note: the discogs-load binary does not accept --db-port; omit it.
  nohup "$RELEASE_BIN" "$RELEASE_FILE" --db-host "$DB_HOST" --db-user "$DB_USER" --db-password "$DB_PASS" --db-name "$DB_NAME" --batch-size "$BATCH_SIZE" > "$LOG_FILE" 2>&1 &
  IMPORT_PID=$!
  echo "$IMPORT_PID" > "$PID_FILE"
  echo "Importer PID: $IMPORT_PID" >> "$LOG_FILE"

  # Wait for the importer to exit.
  while kill -0 "$IMPORT_PID" >/dev/null 2>&1; do
    sleep 30
  done

  wait "$IMPORT_PID"
  echo "Importer finished at $(date)" >> "$LOG_FILE"

  # Create indexes if requested
  if [ "$CREATE_INDEXES_AFTER_IMPORT" = yes ]; then
    echo "Creating indexes with sql/indexes_safe.sql" >> "$LOG_FILE"
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f sql/indexes_safe.sql >> "$LOG_FILE" 2>&1
    echo "Index creation finished at $(date)" >> "$LOG_FILE"
  fi

  echo "All done at $(date)" >> "$LOG_FILE"
}

main "$@"

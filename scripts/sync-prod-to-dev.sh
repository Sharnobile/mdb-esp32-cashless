#!/usr/bin/env bash
# sync-prod-to-dev.sh — refresh the local Supabase CLI dev DB with production data.
# Design: docs/superpowers/specs/2026-05-29-prod-to-dev-data-sync-design.md
# Portable to macOS system bash 3.2 — no bash-4-only features.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_TOML="$REPO_ROOT/Docker/supabase/config.toml"
SUPABASE_PROJECT_DIR="$REPO_ROOT/Docker"
ENV_FILE="$SCRIPT_DIR/sync-prod-to-dev.env"
WORKDIR="$REPO_ROOT/tmp/sync"

# Flag defaults
ASSUME_YES=false
CLEAN_CACHE=false
KEEP_DUMPS=false
SKIP_IMAGES=false
DRY_RUN=false

# DEV_DB_CONTAINER is resolved in preflight()
DEV_DB_CONTAINER=""

# ---------- pure helpers (unit-tested in scripts/test/test-sync-helpers.sh) ----------

mime_for() {
  # $1 = filename/object name → echoes a Content-Type
  local lower
  lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.png)        echo "image/png" ;;
    *.jpg|*.jpeg) echo "image/jpeg" ;;
    *.webp)       echo "image/webp" ;;
    *)            echo "application/octet-stream" ;;
  esac
}

dev_db_container() {
  # $1 = path to config.toml → echoes the local CLI db container name
  local cfg="$1" pid
  pid="$(grep -E '^[[:space:]]*project_id[[:space:]]*=' "$cfg" | head -n1 | cut -d'"' -f2)"
  if [[ -z "$pid" ]]; then
    echo "ERROR: project_id not found in $cfg" >&2
    return 1
  fi
  echo "supabase_db_${pid}"
}

dump_looks_like_sql() {
  # $1 = path to a dump file. Returns 0 if it looks like pg_dump SQL output.
  local f="$1" line
  [[ -s "$f" ]] || return 1
  line="$(grep -m1 -vE '^[[:space:]]*$' "$f" 2>/dev/null || true)"
  [[ "$line" =~ ^(SET|SELECT|--|\\) ]]
}

build_truncate_stmt() {
  # $1 = comma-separated list of fully-qualified public tables
  # → one TRUNCATE covering all public tables + auth.users (CASCADE clears auth internals).
  printf 'TRUNCATE %s, auth.users RESTART IDENTITY CASCADE;' "$1"
}

# ---------- integration phases (verified via --dry-run, not unit-tested) ----------

preflight() {
  local tool ans=""
  for tool in docker rsync ssh curl supabase; do
    command -v "$tool" >/dev/null 2>&1 \
      || { echo "ERROR: required tool not found on PATH: $tool" >&2; exit 1; }
  done

  [[ -f "$ENV_FILE" ]] || {
    echo "ERROR: config not found: $ENV_FILE" >&2
    echo "       Copy scripts/sync-prod-to-dev.env.example and fill it in." >&2
    exit 1; }
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  : "${PROD_SSH:?set PROD_SSH in $ENV_FILE}"
  : "${PROD_DIR:?set PROD_DIR in $ENV_FILE}"
  : "${PROD_STORAGE_DIR:?set PROD_STORAGE_DIR in $ENV_FILE}"
  : "${DEV_SUPABASE_URL:?set DEV_SUPABASE_URL in $ENV_FILE}"

  # Dev guard: target is resolved purely from local config.toml → local container only.
  DEV_DB_CONTAINER="$(dev_db_container "$CONFIG_TOML")"
  docker ps --format '{{.Names}}' | grep -qx "$DEV_DB_CONTAINER" || {
    echo "ERROR: dev DB container '$DEV_DB_CONTAINER' is not running." >&2
    echo "       Start the local stack first: (cd Docker && supabase start)" >&2
    exit 1; }
  docker exec "$DEV_DB_CONTAINER" pg_isready -U postgres >/dev/null 2>&1 || {
    echo "ERROR: dev DB not accepting connections in $DEV_DB_CONTAINER" >&2; exit 1; }

  echo "==> Applying any pending migrations to the dev DB (non-destructive)..."
  ( cd "$SUPABASE_PROJECT_DIR" && supabase migration up ) || {
    echo "ERROR: 'supabase migration up' failed" >&2; exit 1; }

  if ! $ASSUME_YES && ! $DRY_RUN; then
    echo ""
    echo "This will REPLACE ALL DATA in your local dev DB"
    echo "  container : $DEV_DB_CONTAINER"
    echo "  source    : $PROD_SSH (read-only)"
    printf "Continue? [y/N] "
    read -r ans
    [[ "$ans" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
  fi
}

dump_prod() {
  if $DRY_RUN; then
    echo "[dry-run] would dump public + auth.{users,identities} (data-only) from $PROD_SSH"
    return 0
  fi
  echo "==> Dumping public schema from prod (data-only)..."
  ssh "$PROD_SSH" "cd '$PROD_DIR' && docker compose exec -T db \
    pg_dump -U postgres -d postgres --data-only --no-owner --no-privileges \
    --schema=public 2>/dev/null" > "$WORKDIR/public.sql"
  dump_looks_like_sql "$WORKDIR/public.sql" || {
    echo "ERROR: public dump does not look like SQL (SSH/compose error?)" >&2; exit 1; }

  echo "==> Dumping auth.users + auth.identities from prod (data-only)..."
  ssh "$PROD_SSH" "cd '$PROD_DIR' && docker compose exec -T db \
    pg_dump -U postgres -d postgres --data-only --no-owner --no-privileges \
    --table=auth.users --table=auth.identities 2>/dev/null" > "$WORKDIR/auth.sql"
  dump_looks_like_sql "$WORKDIR/auth.sql" || {
    echo "ERROR: auth dump does not look like SQL (SSH/compose error?)" >&2; exit 1; }
}

fetch_images() {
  local img_dir
  if $DRY_RUN; then
    echo "[dry-run] would find product-images under $PROD_STORAGE_DIR and rsync it to $WORKDIR/product-images/"
    return 0
  fi
  echo "==> Locating product-images on prod..."
  img_dir="$(ssh "$PROD_SSH" "find '$PROD_STORAGE_DIR' -type d -name product-images | head -n1")"
  if [[ -z "$img_dir" ]]; then
    echo "WARN: no 'product-images' directory found under $PROD_STORAGE_DIR; skipping images." >&2
    return 0
  fi
  echo "==> Syncing images from $img_dir ..."
  mkdir -p "$WORKDIR/product-images"
  rsync -a -e ssh "$PROD_SSH:$img_dir/" "$WORKDIR/product-images/"
}

restore_db() {
  local public_tables truncate_stmt
  public_tables="$(docker exec "$DEV_DB_CONTAINER" psql -tA -U postgres -d postgres -c \
    "SELECT string_agg(format('%I.%I', schemaname, tablename), ', ') FROM pg_tables WHERE schemaname='public'")"
  [[ -n "$public_tables" ]] || { echo "ERROR: could not list public tables in dev" >&2; exit 1; }
  truncate_stmt="$(build_truncate_stmt "$public_tables")"

  if $DRY_RUN; then
    echo "[dry-run] would restore into $DEV_DB_CONTAINER inside one transaction:"
    echo "  BEGIN; SET session_replication_role = replica;"
    echo "  $truncate_stmt"
    echo "  \\i auth.sql ; \\i public.sql"
    echo "  SET session_replication_role = default; COMMIT;"
    return 0
  fi

  echo "==> Restoring into dev (single transaction, triggers/FK off)..."
  {
    echo "BEGIN;"
    echo "SET session_replication_role = replica;"
    echo "$truncate_stmt"
    cat "$WORKDIR/auth.sql"
    cat "$WORKDIR/public.sql"
    echo "SET session_replication_role = default;"
    echo "COMMIT;"
  } | docker exec -i "$DEV_DB_CONTAINER" psql -v ON_ERROR_STOP=1 -U postgres -d postgres
}

# ---------- entry point ----------

main() {
  mkdir -p "$WORKDIR"
  preflight
  echo "preflight OK (container=$DEV_DB_CONTAINER)"
}

# Only run main when executed directly, not when sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

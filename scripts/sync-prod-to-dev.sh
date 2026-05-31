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
  pid="$(grep -E '^[[:space:]]*project_id[[:space:]]*=' "$cfg" | head -n1 | cut -d'"' -f2 || true)"
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
  # No RESTART IDENTITY: CASCADE reaches auth-owned sequences (e.g. refresh_tokens_id_seq)
  # that the non-superuser `postgres` role cannot reset; public sequence values are restored
  # by the setval() calls already present in the data-only dump.
  printf 'TRUNCATE %s, auth.users CASCADE;' "$1"
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
  # Use --workdir (NOT `cd`): the Bun-based supabase CLI parses ./supabase/.env
  # strictly line-by-line in the cwd-resolution path and rejects multi-line values
  # (e.g. a PEM APNS_PRIVATE_KEY); the --workdir path avoids that parse.
  supabase --workdir "$SUPABASE_PROJECT_DIR" migration up || {
    echo "ERROR: 'supabase migration up' failed" >&2; exit 1; }

  if ! $ASSUME_YES && ! $DRY_RUN; then
    echo ""
    echo "This will REPLACE ALL DATA in your local dev DB"
    echo "  container : $DEV_DB_CONTAINER"
    echo "  source    : $PROD_SSH (read-only)"
    printf "Continue? [y/N] "
    read -r ans || true
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

upload_images() {
  local key namedir obj file mime code total=0 fails=0
  if $DRY_RUN; then
    echo "[dry-run] would upload each product-images object via POST $DEV_SUPABASE_URL/storage/v1/object/product-images/<name>"
    return 0
  fi
  [[ -d "$WORKDIR/product-images" ]] || { echo "No images to upload."; return 0; }

  # --workdir (not `cd`): see the note in preflight() re: the CLI's .env parser.
  key="$( supabase --workdir "$SUPABASE_PROJECT_DIR" status -o env \
          | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p' || true )"
  [[ -n "$key" ]] || { echo "ERROR: could not read SERVICE_ROLE_KEY from 'supabase status'" >&2; exit 1; }

  echo "==> Uploading product images to dev Storage API..."
  # process substitution (not a pipe) so the counters persist in this shell
  while IFS= read -r namedir; do
    obj="$(basename "$namedir")"
    file="$(ls -t "$namedir" 2>/dev/null | head -n1)"
    [[ -n "$file" ]] || continue
    file="$namedir/$file"
    mime="$(mime_for "$obj")"
    total=$((total+1))
    code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
      "$DEV_SUPABASE_URL/storage/v1/object/product-images/$obj" \
      -H "Authorization: Bearer $key" \
      -H "Content-Type: $mime" \
      -H "x-upsert: true" \
      --data-binary "@$file" || echo 000)"
    if [[ ! "$code" =~ ^2 ]]; then
      echo "WARN: upload failed (HTTP $code) for $obj" >&2
      fails=$((fails+1))
    fi
  done < <(find "$WORKDIR/product-images" -mindepth 1 -maxdepth 1 -type d)

  echo "Images uploaded: $((total - fails))/$total ($fails failed)."
}

verify_and_cleanup() {
  echo "==> Row counts in dev:"
  docker exec "$DEV_DB_CONTAINER" psql -U postgres -d postgres -c "
    SELECT 'auth.users'            AS entity, count(*) FROM auth.users
    UNION ALL SELECT 'companies',      count(*) FROM public.companies
    UNION ALL SELECT 'embeddeds',      count(*) FROM public.embeddeds
    UNION ALL SELECT 'vendingMachine', count(*) FROM public.\"vendingMachine\"
    UNION ALL SELECT 'products',       count(*) FROM public.products
    UNION ALL SELECT 'sales',          count(*) FROM public.sales
    UNION ALL SELECT 'storage(images)',count(*) FROM storage.objects WHERE bucket_id='product-images';"

  if [[ -d "$WORKDIR/product-images" ]]; then
    local local_imgs
    local_imgs="$(find "$WORKDIR/product-images" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
    echo "Local image objects fetched: $local_imgs (storage(images) below this = uploads skipped for size/mime)."
  fi

  if ! $KEEP_DUMPS; then rm -f "$WORKDIR/public.sql" "$WORKDIR/auth.sql"; fi
  if $CLEAN_CACHE; then rm -rf "$WORKDIR/product-images"; fi
}

# ---------- entry point ----------

usage() {
  cat <<'EOF'
Usage: scripts/sync-prod-to-dev.sh [options]

Refreshes the local Supabase CLI dev DB with production data
(clones prod auth.users/identities + all public data + product images).

Options:
  --yes          Skip the confirmation prompt (for unattended/cron runs)
  --dry-run      Preview; makes no writes (reads the dev DB catalog read-only to show the exact TRUNCATE)
  --skip-images  Refresh the DB only (no image fetch/upload)
  --keep-dumps   Keep tmp/sync/*.sql after the run
  --clean        Also delete the tmp/sync/product-images cache after the run
  -h, --help     Show this help

Config: scripts/sync-prod-to-dev.env (copy from .env.example). Requires a
running local stack (cd Docker && supabase start).
EOF
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes)         ASSUME_YES=true ;;
      --dry-run)     DRY_RUN=true ;;
      --skip-images) SKIP_IMAGES=true ;;
      --keep-dumps)  KEEP_DUMPS=true ;;
      --clean)       CLEAN_CACHE=true ;;
      -h|--help)     usage; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
    shift
  done

  mkdir -p "$WORKDIR"
  preflight
  dump_prod
  $SKIP_IMAGES || fetch_images
  restore_db
  $SKIP_IMAGES || upload_images
  verify_and_cleanup
  echo ""
  echo "Done. Log into dev (http://localhost:3000) with your PRODUCTION credentials."
}

# Only run main when executed directly, not when sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

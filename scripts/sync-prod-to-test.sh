#!/usr/bin/env bash
# sync-prod-to-test.sh — refresh the TEST server's DB + product images with production data.
# Runs ON the test box. Pulls prod read-only over SSH; all destructive work is LOCAL.
# Design: docs/superpowers/specs/2026-06-08-prod-to-test-data-sync-design.md
# Portable to macOS/Linux bash 3.2 — no bash-4-only features.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$REPO_ROOT/Docker"                 # this box's compose dir (restore target)
TEST_ENV="$TEST_DIR/.env"                    # the full Supabase env file on this box
ENV_FILE="$SCRIPT_DIR/sync-prod-to-test.env" # operator config (PROD_SSH, expected domain)
WORKDIR="$REPO_ROOT/tmp/sync-test"

# Flag defaults
ASSUME_YES=false
CLEAN_CACHE=false
KEEP_DUMPS=false
SKIP_IMAGES=false
DRY_RUN=false

# Resolved in preflight()
TEST_PUBLIC_URL=""
TEST_SERVICE_KEY=""
TEST_SUPABASE_URL=""
PROD_PUBLIC_URL=""

# ---------- pure helpers (unit-tested in scripts/test/test-sync-test-helpers.sh) ----------

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
  # No RESTART IDENTITY: CASCADE reaches auth-owned sequences the non-superuser `postgres`
  # role cannot reset; public sequence values are restored by the dump's setval() calls.
  printf 'TRUNCATE %s, auth.users CASCADE;' "$1"
}

read_env_value() {
  # $1 = path to a .env file, $2 = key. Echoes the value (surrounding quotes +
  # trailing CR stripped). Returns 1 if the file or key is absent / value empty.
  # Uses grep|cut, NEVER `source`: the full Supabase .env ships unquoted values
  # with spaces (STUDIO_DEFAULT_ORGANIZATION=Default Organization) and multi-line
  # PEM blocks (APNS_PRIVATE_KEY) that `source` mis-parses. cut -f2- keeps any
  # '=' in the value (e.g. a JWT's trailing '==' padding). See Docker/update.sh.
  local file="$1" key="$2" val
  [[ -f "$file" ]] || return 1
  val="$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | head -n1 | cut -d= -f2-)"
  [[ -n "$val" ]] || return 1
  val="${val%$'\r'}"                  # strip trailing CR (CRLF files)
  val="${val#\"}"; val="${val%\"}"    # strip surrounding double quotes
  val="${val#\'}"; val="${val%\'}"    # strip surrounding single quotes
  printf '%s' "$val"
}

domain_in_url() {
  # $1 = url, $2 = expected domain substring. rc 0 if present, 1 otherwise.
  # Guard A's decision: the test box's SUPABASE_PUBLIC_URL must contain the
  # operator-configured test domain. Substring containment is by design.
  local url="$1" domain="$2"
  [[ -n "$domain" ]] || return 1
  [[ "$url" == *"$domain"* ]]
}

migrations_match() {
  # $1=prod_max $2=prod_count $3=test_max $4=test_count → rc 0 only if BOTH the
  # latest-applied migration filename and the applied count match. Guard C's
  # decision: detects the common version-drift case before any write. (True
  # schema skew that slips past is still caught by the atomic restore rollback.)
  [[ "$1" == "$3" && "$2" == "$4" ]]
}

# ---------- integration phases (verified via --dry-run, not unit-tested) ----------

preflight() {
  local tool ans=""
  for tool in docker ssh rsync curl; do
    command -v "$tool" >/dev/null 2>&1 \
      || { echo "ERROR: required tool not found on PATH: $tool" >&2; exit 1; }
  done

  [[ -f "$ENV_FILE" ]] || {
    echo "ERROR: config not found: $ENV_FILE" >&2
    echo "       Copy scripts/sync-prod-to-test.env.example and fill it in." >&2
    exit 1; }
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  : "${PROD_SSH:?set PROD_SSH in $ENV_FILE}"
  : "${PROD_DIR:?set PROD_DIR in $ENV_FILE}"
  : "${PROD_STORAGE_DIR:?set PROD_STORAGE_DIR in $ENV_FILE}"
  : "${TEST_EXPECTED_DOMAIN:?set TEST_EXPECTED_DOMAIN in $ENV_FILE}"

  [[ -f "$TEST_ENV" ]] || { echo "ERROR: test stack env not found: $TEST_ENV" >&2; exit 1; }
  [[ -f "$TEST_DIR/docker-compose.yml" ]] || { echo "ERROR: $TEST_DIR is not a compose dir (no docker-compose.yml)" >&2; exit 1; }

  # Read this box's identity from its own Docker/.env (grep|cut, never source).
  TEST_PUBLIC_URL="$(read_env_value "$TEST_ENV" SUPABASE_PUBLIC_URL || true)"
  TEST_SERVICE_KEY="$(read_env_value "$TEST_ENV" SERVICE_ROLE_KEY || true)"
  local kong_port; kong_port="$(read_env_value "$TEST_ENV" KONG_HTTP_PORT || true)"
  [[ -n "$kong_port" ]] || kong_port=8000
  TEST_SUPABASE_URL="http://localhost:${kong_port}"
  [[ -n "$TEST_PUBLIC_URL" ]]  || { echo "ERROR: SUPABASE_PUBLIC_URL missing from $TEST_ENV" >&2; exit 1; }
  [[ -n "$TEST_SERVICE_KEY" ]] || { echo "ERROR: SERVICE_ROLE_KEY missing from $TEST_ENV" >&2; exit 1; }

  # --- Guard A: this box self-identifies as test ---
  domain_in_url "$TEST_PUBLIC_URL" "$TEST_EXPECTED_DOMAIN" || {
    echo "ERROR: safety guard A failed." >&2
    echo "  This box's SUPABASE_PUBLIC_URL ($TEST_PUBLIC_URL)" >&2
    echo "  does not contain TEST_EXPECTED_DOMAIN ($TEST_EXPECTED_DOMAIN)." >&2
    echo "  Refusing — this may be the PROD box or a misconfiguration." >&2
    exit 1; }

  # --- Connectivity: local test DB must be up before we probe further ---
  ( cd "$TEST_DIR" && docker compose exec -T db pg_isready -U postgres ) >/dev/null 2>&1 || {
    echo "ERROR: test DB not accepting connections (cd $TEST_DIR && docker compose exec db pg_isready)" >&2
    echo "       Start the test stack first: (cd $TEST_DIR && docker compose up -d)" >&2
    exit 1; }

  # --- Guard B: source != target (read prod's public URL over SSH) ---
  # `|| true` so an SSH/read failure falls through to the diagnostic below instead
  # of aborting mid-substitution under `set -e`/`pipefail`. Strip CR + surrounding
  # quotes the same way read_env_value does, so prod and test are compared symmetrically.
  PROD_PUBLIC_URL="$(ssh "$PROD_SSH" "grep -E '^[[:space:]]*SUPABASE_PUBLIC_URL=' '$PROD_DIR/.env' | head -n1 | cut -d= -f2-" 2>/dev/null | tr -d '\r' || true)"
  PROD_PUBLIC_URL="${PROD_PUBLIC_URL#\"}"; PROD_PUBLIC_URL="${PROD_PUBLIC_URL%\"}"
  PROD_PUBLIC_URL="${PROD_PUBLIC_URL#\'}"; PROD_PUBLIC_URL="${PROD_PUBLIC_URL%\'}"
  [[ -n "$PROD_PUBLIC_URL" ]] || {
    echo "ERROR: could not read prod SUPABASE_PUBLIC_URL over SSH ($PROD_SSH : $PROD_DIR/.env)" >&2
    echo "       Check PROD_SSH / PROD_DIR and that this box can SSH to prod." >&2
    exit 1; }
  [[ "$PROD_PUBLIC_URL" != "$TEST_PUBLIC_URL" ]] || {
    echo "ERROR: safety guard B failed — prod and test SUPABASE_PUBLIC_URL are identical:" >&2
    echo "  $TEST_PUBLIC_URL" >&2
    echo "  Source and target must differ. Refusing." >&2
    exit 1; }

  # --- Guard C: migration parity (max(name) + count from public._migrations) ---
  # `|| true` on each capture so a read failure falls through to the explicit
  # checks below rather than aborting mid-substitution under `set -e`/`pipefail`.
  local prod_max prod_cnt test_max test_cnt
  prod_max="$(ssh "$PROD_SSH" "cd '$PROD_DIR' && docker compose exec -T db psql -tA -U postgres -d postgres -c \"SELECT COALESCE(max(name),'') FROM public._migrations\"" 2>/dev/null | tr -d '\r' || true)"
  prod_cnt="$(ssh "$PROD_SSH" "cd '$PROD_DIR' && docker compose exec -T db psql -tA -U postgres -d postgres -c 'SELECT count(*) FROM public._migrations'" 2>/dev/null | tr -d '\r' || true)"
  test_max="$( ( cd "$TEST_DIR" && docker compose exec -T db psql -tA -U postgres -d postgres -c "SELECT COALESCE(max(name),'') FROM public._migrations" ) 2>/dev/null | tr -d '\r' || true)"
  test_cnt="$( ( cd "$TEST_DIR" && docker compose exec -T db psql -tA -U postgres -d postgres -c 'SELECT count(*) FROM public._migrations' ) 2>/dev/null | tr -d '\r' || true)"
  # count(*) is "0" for an empty table and "" only when the probe itself failed,
  # so empty counts mean a failed read — abort rather than let an all-empty
  # "match" pass Guard C spuriously.
  [[ -n "$prod_cnt" && -n "$test_cnt" ]] || {
    echo "ERROR: could not read public._migrations from prod and/or test (SSH/compose error?)." >&2
    echo "  prod: max=[$prod_max] count=[$prod_cnt]   test: max=[$test_max] count=[$test_cnt]" >&2
    exit 1; }
  migrations_match "$prod_max" "$prod_cnt" "$test_max" "$test_cnt" || {
    echo "ERROR: safety guard C failed — migration state differs between prod and test:" >&2
    echo "  prod: max=[$prod_max] count=[$prod_cnt]" >&2
    echo "  test: max=[$test_max] count=[$test_cnt]" >&2
    echo "  Deploy/pull the test server to prod's migration version first, then re-run." >&2
    exit 1; }

  echo "==> Guards passed."
  echo "    source (read-only): $PROD_SSH   $PROD_PUBLIC_URL"
  echo "    target (this box) : $TEST_DIR   $TEST_PUBLIC_URL"

  if ! $ASSUME_YES && ! $DRY_RUN; then
    echo ""
    echo "This will REPLACE ALL DATA in the TEST database with production data."
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
  public_tables="$( ( cd "$TEST_DIR" && docker compose exec -T db psql -tA -U postgres -d postgres -c \
    "SELECT string_agg(format('%I.%I', schemaname, tablename), ', ') FROM pg_tables WHERE schemaname='public'" ) 2>/dev/null | tr -d '\r' || true )"
  [[ -n "$public_tables" ]] || { echo "ERROR: could not list public tables in the test DB (is the test stack up?)" >&2; exit 1; }
  truncate_stmt="$(build_truncate_stmt "$public_tables")"

  if $DRY_RUN; then
    echo "[dry-run] would restore into the TEST db inside one transaction:"
    echo "  BEGIN; SET session_replication_role = replica;"
    echo "  $truncate_stmt"
    echo "  <auth.sql> ; <public.sql>"
    echo "  SET session_replication_role = default; COMMIT;"
    return 0
  fi

  echo "==> Restoring into test (single transaction, triggers/FK off)..."
  {
    echo "BEGIN;"
    echo "SET session_replication_role = replica;"
    echo "$truncate_stmt"
    cat "$WORKDIR/auth.sql"
    cat "$WORKDIR/public.sql"
    echo "SET session_replication_role = default;"
    echo "COMMIT;"
  } | ( cd "$TEST_DIR" && docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres )
}

upload_images() {
  local namedir obj file mime code total=0 fails=0
  if $DRY_RUN; then
    echo "[dry-run] would upload each product-images object via POST $TEST_SUPABASE_URL/storage/v1/object/product-images/<name>"
    return 0
  fi
  [[ -d "$WORKDIR/product-images" ]] || { echo "No images to upload."; return 0; }

  echo "==> Uploading product images to the test Storage API ($TEST_SUPABASE_URL)..."
  # process substitution (not a pipe) so the counters persist in this shell
  while IFS= read -r namedir; do
    obj="$(basename "$namedir")"
    file="$(ls -t "$namedir" 2>/dev/null | head -n1)"
    [[ -n "$file" ]] || continue
    file="$namedir/$file"
    mime="$(mime_for "$obj")"
    total=$((total+1))
    code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
      "$TEST_SUPABASE_URL/storage/v1/object/product-images/$obj" \
      -H "Authorization: Bearer $TEST_SERVICE_KEY" \
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
  echo "==> Row counts in test:"
  ( cd "$TEST_DIR" && docker compose exec -T db psql -U postgres -d postgres -c "
    SELECT 'auth.users'            AS entity, count(*) FROM auth.users
    UNION ALL SELECT 'companies',      count(*) FROM public.companies
    UNION ALL SELECT 'embeddeds',      count(*) FROM public.embeddeds
    UNION ALL SELECT 'vendingMachine', count(*) FROM public.\"vendingMachine\"
    UNION ALL SELECT 'products',       count(*) FROM public.products
    UNION ALL SELECT 'sales',          count(*) FROM public.sales
    UNION ALL SELECT 'storage(images)',count(*) FROM storage.objects WHERE bucket_id='product-images';" )

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
Usage: scripts/sync-prod-to-test.sh [options]

Refreshes the TEST server's database + product images with PRODUCTION data.
Run this ON THE TEST BOX. Prod is read-only; all destructive work is local.

Options:
  --yes          Skip the confirmation prompt (for unattended/cron runs)
  --dry-run      Run the read-only safety guards and print planned actions; makes no writes
  --skip-images  Refresh the DB only (no image fetch/upload)
  --keep-dumps   Keep tmp/sync-test/*.sql after the run
  --clean        Also delete the tmp/sync-test/product-images cache after the run
  -h, --help     Show this help

Config: scripts/sync-prod-to-test.env (copy from .env.example).
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
  echo "Done. Log into the test frontend ($TEST_PUBLIC_URL) with your production credentials."
}

# Only run main when executed directly, not when sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

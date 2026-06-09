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
# (added in Chunk 2)
preflight()           { echo "TODO preflight"; }
dump_prod()           { echo "TODO dump_prod"; }
fetch_images()        { echo "TODO fetch_images"; }
restore_db()          { echo "TODO restore_db"; }
upload_images()       { echo "TODO upload_images"; }
verify_and_cleanup()  { echo "TODO verify_and_cleanup"; }

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

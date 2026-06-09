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
# (added in Tasks 2–4)

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

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

dump_looks_like_sql() {
  # $1 = path to a dump file. Returns 0 if it looks like pg_dump SQL output.
  local f="$1" line
  [[ -s "$f" ]] || return 1
  line="$(grep -m1 -vE '^[[:space:]]*$' "$f" 2>/dev/null || true)"
  [[ "$line" =~ ^(SET|SELECT|--|\\) ]]
}

dev_db_container() {
  # $1 = path to config.toml → echoes the local CLI db container name
  local cfg="$1" pid
  pid="$(grep -E '^[[:space:]]*project_id' "$cfg" | head -n1 | cut -d'"' -f2)"
  if [[ -z "$pid" ]]; then
    echo "ERROR: project_id not found in $cfg" >&2
    return 1
  fi
  echo "supabase_db_${pid}"
}

# ---------- entry point ----------

main() {
  echo "main not yet implemented" >&2
  exit 1
}

# Only run main when executed directly, not when sourced by tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

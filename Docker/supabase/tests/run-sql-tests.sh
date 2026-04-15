#!/usr/bin/env bash
set -euo pipefail

# Run every *.test.sql in this directory against the local Supabase DB.
# Requires `supabase start` to have been run first.
#
# Override PSQL or TEST_DB_URL if your psql is not on PATH or your local
# Supabase binds a different port.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_URL="${TEST_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

# Locate psql: prefer $PSQL, then PATH, then Homebrew libpq keg
PSQL_BIN="${PSQL:-}"
if [[ -z "$PSQL_BIN" ]]; then
  if command -v psql >/dev/null 2>&1; then
    PSQL_BIN="$(command -v psql)"
  elif [[ -x /opt/homebrew/opt/libpq/bin/psql ]]; then
    PSQL_BIN="/opt/homebrew/opt/libpq/bin/psql"
  elif [[ -x /usr/local/opt/libpq/bin/psql ]]; then
    PSQL_BIN="/usr/local/opt/libpq/bin/psql"
  else
    echo "ERROR: psql not found. Install libpq or set PSQL=/path/to/psql." >&2
    exit 127
  fi
fi

shopt -s nullglob
files=("$DIR"/*.test.sql)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No *.test.sql files found in $DIR"
  exit 0
fi

fail=0
for f in "${files[@]}"; do
  echo "── Running $(basename "$f") ──"
  if "$PSQL_BIN" "$DB_URL" -v ON_ERROR_STOP=1 -f "$f"; then
    echo "  PASS"
  else
    echo "  FAIL"
    fail=1
  fi
done

exit $fail

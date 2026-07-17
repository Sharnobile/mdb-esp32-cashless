#!/usr/bin/env bash
# Seed (or re-seed) the App Store review demo organisation.
#
# Runs scripts/seed-demo-org.sql against the target database, confined to a
# fixed demo company id — safe to re-run before every submission.
#
# Required env:
#   DEMO_DB_URL         Postgres connection string for the target DB
#                       (e.g. the prod DB, or postgresql://postgres:postgres@127.0.0.1:54322/postgres for local)
#   DEMO_ADMIN_EMAIL    the demo login account — must ALREADY exist in auth.users
#                       (register it in the app / Supabase Studio first)
# Optional env:
#   DEMO_SECOND_ADMIN_EMAIL  a second admin so deleting the demo account takes
#                            the ordinary one-tap path and the org survives.
#                            Unset → sole admin (deletion cascades the company).
#
# Usage:
#   DEMO_DB_URL=... DEMO_ADMIN_EMAIL=review@vmflow.demo scripts/seed-demo-org.sh
#   scripts/seed-demo-org.sh --dry-run     # print what it would do, run nothing
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL="$DIR/seed-demo-org.sql"

: "${DEMO_DB_URL:?set DEMO_DB_URL to the target Postgres connection string}"
: "${DEMO_ADMIN_EMAIL:?set DEMO_ADMIN_EMAIL to the demo login account email}"
SECOND="${DEMO_SECOND_ADMIN_EMAIL:-}"

# Locate psql (PATH, then Homebrew libpq keg)
PSQL="${PSQL:-}"
if [[ -z "$PSQL" ]]; then
  if command -v psql >/dev/null 2>&1; then PSQL="$(command -v psql)"
  elif [[ -x /opt/homebrew/opt/libpq/bin/psql ]]; then PSQL="/opt/homebrew/opt/libpq/bin/psql"
  elif [[ -x /usr/local/opt/libpq/bin/psql ]]; then PSQL="/usr/local/opt/libpq/bin/psql"
  else echo "ERROR: psql not found. Install libpq or set PSQL=/path/to/psql." >&2; exit 127; fi
fi

# Mask credentials when echoing the target.
host_only="$(printf '%s' "$DEMO_DB_URL" | sed -E 's#^[^@]*@#…@#')"
echo "Target   : $host_only"
echo "Admin    : $DEMO_ADMIN_EMAIL"
echo "2nd admin: ${SECOND:-(none — sole admin, deletion cascades the company)}"

if [[ "${1:-}" == "--dry-run" ]]; then
  echo "(dry run) would run: $SQL"
  exit 0
fi

read -r -p "Seed the demo org on the target above? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 1; }

"$PSQL" "$DEMO_DB_URL" \
  -v admin_email="$DEMO_ADMIN_EMAIL" \
  -v second_admin_email="$SECOND" \
  -f "$SQL"

echo "Done. Demo login: $DEMO_ADMIN_EMAIL"

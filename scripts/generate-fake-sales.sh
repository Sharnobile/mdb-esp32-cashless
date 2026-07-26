#!/usr/bin/env bash
# Generate fake/simulated sales ("mouvements de ventes") for existing vending
# machines on THIS box's own Docker stack — local test/demo purposes only.
#
# Run it on the test server, from the repo root, with the stack up:
#   (cd Docker && docker compose up -d)
#
# It picks random existing machine_trays that already have a product
# assigned, and bulk-inserts sales spread over the last N days with a small
# price jitter around each product's real sellprice. By default it does NOT
# touch machine_trays.current_stock (backdated fake sales shouldn't move
# today's real stock levels) — pass --adjust-stock to opt in.
#
# Every inserted sale id is printed and saved to tmp/fake-sales/<ts>.ids so a
# later run can undo exactly this batch with --undo <file>.
#
# Usage:
#   scripts/generate-fake-sales.sh [options]
#   scripts/generate-fake-sales.sh --undo tmp/fake-sales/20260726-153000.ids
#
# Options:
#   --company <uuid>   restrict to one company (default: all companies)
#   --machine <uuid>   restrict to one machine (default: all machines)
#   --count <N>        number of fake sales to generate (default: 200)
#   --days <N>         spread sales over the last N days (default: 30)
#   --adjust-stock     also decrement machine_trays.current_stock (default: off)
#   --yes              skip the confirmation prompt
#   --dry-run          show what would run, write nothing
#   --undo <file>      delete exactly the sales listed in a previous run's .ids file
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
SQL="$DIR/generate-fake-sales.sql"

COMPANY=""
MACHINE=""
COUNT=200
DAYS=30
ADJUST_STOCK=false
ASSUME_YES=false
DRY_RUN=false
UNDO_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --company) COMPANY="$2"; shift 2 ;;
    --machine) MACHINE="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --adjust-stock) ADJUST_STOCK=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --undo) UNDO_FILE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

run_psql() {
  ( cd "$REPO_ROOT/Docker" && docker compose exec -T db psql -U postgres -d postgres "$@" )
}

if [[ -n "$UNDO_FILE" ]]; then
  [[ -f "$UNDO_FILE" ]] || { echo "ERROR: ids file not found: $UNDO_FILE" >&2; exit 1; }
  n="$(wc -l < "$UNDO_FILE" | tr -d ' ')"
  echo "Will delete $n fake sale(s) listed in $UNDO_FILE (stock is NOT auto-restored — pass --adjust-stock at generation time only if you also plan to reconcile stock by hand)."
  if [[ "$DRY_RUN" == true ]]; then
    echo "(dry run) would run: DELETE FROM sales WHERE id = ANY(<ids from $UNDO_FILE>)"
    exit 0
  fi
  if [[ "$ASSUME_YES" != true ]]; then
    read -r -p "Proceed? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 1; }
  fi
  ids_csv="$(sed "s/.*/'&'/" "$UNDO_FILE" | paste -sd,)"
  run_psql -v ON_ERROR_STOP=1 -c "DELETE FROM sales WHERE id = ANY(ARRAY[$ids_csv]::uuid[]);"
  echo "Deleted $n sale(s)."
  exit 0
fi

echo "Company filter : ${COMPANY:-(none — all companies)}"
echo "Machine filter : ${MACHINE:-(none — all machines)}"
echo "Count          : $COUNT"
echo "Spread over    : last $DAYS day(s)"
echo "Adjust stock   : $ADJUST_STOCK"

if [[ "$DRY_RUN" == true ]]; then
  echo "(dry run) would run: $SQL"
  exit 0
fi

if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Insert $COUNT fake sales into the test DB? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 1; }
fi

mkdir -p "$REPO_ROOT/tmp/fake-sales"
OUT_FILE="$REPO_ROOT/tmp/fake-sales/$(date +%Y%m%d-%H%M%S).ids"

run_psql -v ON_ERROR_STOP=1 -tA \
  -v count="$COUNT" \
  -v days="$DAYS" \
  -v company_filter="$COMPANY" \
  -v machine_filter="$MACHINE" \
  -v adjust_stock="$ADJUST_STOCK" \
  -f - < "$SQL" > "$OUT_FILE"

n="$(wc -l < "$OUT_FILE" | tr -d ' ')"
echo "Inserted $n fake sale(s)."
echo "Ids saved to: $OUT_FILE"
echo "Undo with   : scripts/generate-fake-sales.sh --undo $OUT_FILE"

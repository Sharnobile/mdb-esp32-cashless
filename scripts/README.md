# scripts/

## sync-prod-to-dev.sh

Refreshes the **local Supabase CLI dev database** with **production data** so you
develop against realistic data. It clones prod `auth.users`/`auth.identities` +
all `public` data + `product-images`, so you log into dev with your **production
credentials**. Design: `docs/superpowers/specs/2026-05-29-prod-to-dev-data-sync-design.md`.

### Prerequisites
- A running local stack: `cd Docker && supabase start`
- Tools on PATH: `docker`, `ssh`, `rsync`, `curl`, `supabase` (no local `psql` needed)
- SSH access to the prod server

### Setup
```bash
cp scripts/sync-prod-to-dev.env.example scripts/sync-prod-to-dev.env
# edit scripts/sync-prod-to-dev.env (PROD_SSH, PROD_DIR, PROD_STORAGE_DIR)
```

### Run
```bash
./scripts/sync-prod-to-dev.sh            # prompts before replacing dev data
./scripts/sync-prod-to-dev.sh --dry-run  # preview — no writes (reads the dev DB catalog read-only to show the exact TRUNCATE)
./scripts/sync-prod-to-dev.sh --skip-images
./scripts/sync-prod-to-dev.sh --yes      # unattended (cron)
```
After it finishes, log in at http://localhost:3000 with your prod email/password.

### Safety
- Prod is **read-only** (pg_dump + rsync only).
- The restore can only target the local CLI container (`supabase_db_<project_id>`
  from `Docker/supabase/config.toml`) — it cannot point at a remote DB.
- The restore is one transaction; any error rolls back and leaves dev untouched.
- It does **not** use `supabase db reset`.

### Scheduling (optional — a refresh overwrites local data, so opt in deliberately)
cron (weekly, Mon 04:00):
```cron
# 0 4 * * 1 cd /path/to/mdb-esp32-cashless && ./scripts/sync-prod-to-dev.sh --yes >> tmp/sync/cron.log 2>&1
```
macOS launchd: create `~/Library/LaunchAgents/com.vmflow.syncprod.plist` with a
`StartCalendarInterval` and `ProgramArguments` of `[/bin/bash, -lc, "cd /path && ./scripts/sync-prod-to-dev.sh --yes"]`,
then `launchctl load` it.

### Auth column-skew fallback
If a sync fails on the `auth.users`/`auth.identities` COPY (because prod runs a
newer GoTrue than your CLI), update your CLI (`supabase` upgrade) so the dev
schema is a superset of prod, then re-run. If you cannot upgrade, replace the
`--table=auth.users`/`--table=auth.identities` dumps with explicit-column
`\copy (SELECT <cols>) TO STDOUT` / `\copy <t>(<cols>) FROM STDIN` using the
stable column lists in the design spec (§ Assumptions & accepted risks).

## sync-prod-to-test.sh

Refreshes the **test server's** database + product images with **production data**.
Run it **on the test box** (from the repo checkout there). It pulls prod read-only
over SSH and does all destructive work locally against this box's own `Docker/`
stack, so you log into test with your **production credentials**.
Design: `docs/superpowers/specs/2026-06-08-prod-to-test-data-sync-design.md`.

### Prerequisites
- Run on the test server, where the full stack is up: `(cd Docker && docker compose up -d)`
- Tools on PATH: `docker`, `ssh`, `rsync`, `curl`
- This box has an (ideally read-only) SSH key authorised on the prod host
- Test is deployed at the **same migration version** as prod (the script aborts otherwise)

### Setup
```bash
cp scripts/sync-prod-to-test.env.example scripts/sync-prod-to-test.env
# edit: PROD_SSH, PROD_DIR, PROD_STORAGE_DIR, TEST_EXPECTED_DOMAIN
```

### Run
```bash
./scripts/sync-prod-to-test.sh            # prompts before replacing the test DB
./scripts/sync-prod-to-test.sh --dry-run  # runs the read-only guards + prints planned actions
./scripts/sync-prod-to-test.sh --skip-images
./scripts/sync-prod-to-test.sh --yes      # unattended (cron)
```

### Safety
- Prod is **read-only** (`pg_dump` + `rsync` + reading `$PROD_DIR/.env`).
- Layered guard before any write: (A) this box's `SUPABASE_PUBLIC_URL` must contain
  `TEST_EXPECTED_DOMAIN`; (B) prod's and test's `SUPABASE_PUBLIC_URL` must differ;
  (C) prod and test must be at the same `public._migrations` state, else it aborts.
- The restore is one transaction; any error rolls back and leaves the test DB untouched.
- The restore target is always this box's own compose `db` service — never a remote DB.
- It does **not** use `supabase db reset` and does **not** run migrations.

### Scheduling (optional — a refresh overwrites the test DB, so opt in deliberately)
cron on the test box (weekly, Mon 04:00):
```cron
# 0 4 * * 1 cd /path/to/mdb-esp32-cashless && ./scripts/sync-prod-to-test.sh --yes >> tmp/sync-test/cron.log 2>&1
```

## generate-fake-sales.sh

Bulk-inserts simulated sales ("mouvements de ventes") into `sales` for your
**existing** machines/trays, spread over a past date range — for making a test
or demo instance look like it has real activity. Run it **on the box whose
`Docker/` stack you want to seed**, from the repo root.

### Prerequisites
- The stack is up: `(cd Docker && docker compose up -d)`
- `docker` on PATH (uses `docker compose exec -T db psql`, no host `psql` needed)

### Run
```bash
./scripts/generate-fake-sales.sh                              # 200 sales, last 30 days, all machines
./scripts/generate-fake-sales.sh --count 500 --days 90         # more sales, longer history
./scripts/generate-fake-sales.sh --company <uuid>               # restrict to one company
./scripts/generate-fake-sales.sh --machine <uuid>               # restrict to one machine
./scripts/generate-fake-sales.sh --adjust-stock                 # also decrement machine_trays.current_stock
./scripts/generate-fake-sales.sh --dry-run
./scripts/generate-fake-sales.sh --yes                          # skip the confirmation prompt
```

Picks random existing `machine_trays` rows that already have a product
assigned, jitters the price ±10% around that product's real `sellprice`, and
spreads `created_at` uniformly across the requested day range. By default it
does **not** touch `current_stock` (backdated fake sales shouldn't move
today's real stock) — the normal `insert_manual_sale` stock-skip mechanism is
reused for this (see `20260602120000_manual_sale_skip_stock.sql`).

### Undo
Every run prints the path to a `tmp/fake-sales/<timestamp>.ids` file listing
exactly the sale ids it inserted:
```bash
./scripts/generate-fake-sales.sh --undo tmp/fake-sales/20260726-160608.ids
```
This only deletes those rows — it does **not** restore stock, even if the
original run used `--adjust-stock` (reconcile that by hand if needed).

### Safety
- Only ever targets this box's own compose `db` service (`docker compose exec`)
  — never a remote DB, never prod.
- Fails clearly (no rows inserted) if `--company`/`--machine` matches no
  `machine_trays` with a product assigned.
- Prompts before writing unless `--yes` is passed.

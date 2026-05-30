# Prod → Dev Data Sync (realistic local data, clones prod logins)

**Date**: 2026-05-29
**Status**: Design — pending user review (rev 2, post spec-review)
**Scope**: New repo tooling under `scripts/` — a repeatable script that refreshes the **local Supabase CLI dev database** with **production data**. No application code, no migrations, no backend behavior change.

## Problem

The developer wants realistic data locally to develop the management frontend / iOS app against. Today the dev DB is whatever `Docker/supabase/seed.sql` produces (one `test@test.com` user, a synthetic "SnackFlow GmbH" company, ~30 days of generated sales). That diverges from production, so UI behavior, edge cases, and data volume don't match reality.

We need a **repeatable, safe** way to pull production data into the local dev DB on demand, such that **logging in still works afterwards** — specifically, the developer wants to log into dev with their **real production credentials** (the full user/company/membership graph comes over, so RLS shows exactly what each prod user sees).

## Topology (the two environments)

| | Production | Local Dev |
|---|---|---|
| Stack | `Docker/docker-compose.yml` (full self-hosted Supabase) | Supabase CLI (`Docker/supabase/`, `supabase start`) |
| Postgres | `supabase/postgres:15.8.1.060` (**major 15**) | **major 17** (`config.toml`) |
| DB reachability | loopback only on the server (`127.0.0.1` + `::1` :5432) | local Docker container, port `54322` |
| Storage files | `Docker/volumes/storage/` on the server (file backend) | inside a CLI-managed Docker volume |
| Auth | GoTrue, `auth` schema | GoTrue, `auth` schema (possibly newer version) |

Two facts drive the whole design:
1. **Postgres major version differs (15 → 17).** A full schema/cluster restore across this gap is fragile. **Moving only row data** into the already-correct dev schema sidesteps it entirely.
2. **The dev schema is owned by the Supabase CLI** (GoTrue/Storage container versions, internal schemas `_supabase`/`_realtime`/`pgsodium`/`vault`). We must **not** drop/recreate it. We refresh **data inside the existing tables**.

## Decisions (captured during brainstorming)

1. **Login model — clone prod auth.** Copy `auth.users` + `auth.identities` + the entire `public` graph so the developer logs in with real prod credentials and RLS is internally consistent. No re-linking step needed.
2. **Source — SSH + `pg_dump` on the server.** The script SSHes to the prod host, runs `pg_dump` inside the `db` container, and streams the dump down. Prod is **read-only** throughout. Always-fresh data.
3. **Storage — DB + product images.** `product-images` files come over; **firmware binaries do not**. Images are re-ingested through the dev Storage API (see Phase 4) rather than copied at the filesystem level — this avoids the xattr-preservation problem.

## Tooling constraints (verified on this machine)

The local machine has `supabase` CLI, `docker`, `rsync`, `ssh`, `curl` — but **no `psql`/`pg_dump` on PATH** (no libpq). Therefore:
- The **dump** runs inside the **prod** `db` container (`docker compose exec -T db pg_dump …`) — prod has it.
- The **restore** runs inside the **dev** CLI DB container (`docker exec -i <dev_db_container> psql …`) — no local libpq needed.
- The **storage upload** uses `curl` against the dev Storage REST API.

This also yields a **stronger safety guard** than parsing a connection URL: the restore can only target the local CLI's own container (see Phase 0).

## Goals

- One command refreshes the local dev DB with production data, repeatably.
- After a refresh, the developer can log into dev with their **production** email + password.
- All `public` business data (companies, embeddeds, vendingMachine, sales, paxcounter, products, trays, warehouse, activity log, …) mirrors prod.
- Product images render in dev (URLs resolve).
- The operation is **atomic** (single transaction) and **guarded** so it can never run against prod and never half-wipes dev.
- Does **not** use `supabase db reset` (honors the project's absolute rule).

## Non-goals

- **No** full cluster clone / no restore of `auth.sessions`, `auth.refresh_tokens`, MFA, or any non-`public` schema other than the two named auth tables.
- **No** firmware-binary copy, **no** `storage.objects` row copy from prod (the re-upload recreates them).
- **No** change to prod (read-only), to migrations, to edge functions, or to app code.
- **No** automatic aggressive scheduling by default — a refresh overwrites local work, so it is a deliberate manual action (a commented cron/launchd example is provided for those who want it).

## Components

| File | Purpose | Git |
|---|---|---|
| `scripts/sync-prod-to-dev.sh` | Orchestrator (bash, `set -euo pipefail`) | committed |
| `scripts/sync-prod-to-dev.env.example` | Config template with documented keys | committed |
| `scripts/sync-prod-to-dev.env` | The developer's real values (SSH host, server path) | **gitignored** |
| `tmp/sync/` | Work dir: SQL dumps + image cache | **gitignored** |
| `.gitignore` | add `tmp/sync/` and `scripts/sync-prod-to-dev.env` (confirmed not currently ignored) | edited |
| `scripts/README.md` (or header comment) | usage + prerequisites + scheduling examples | committed |

The restore wrapper SQL (truncate + load) is **assembled inline** in the bash script and streamed into the dev DB container via stdin — the truncate list is computed dynamically, so no separate SQL file is needed.

### Configuration keys (`sync-prod-to-dev.env`)

```sh
PROD_SSH="user@prod-host"                          # ssh target or ~/.ssh/config alias
PROD_DIR="/home/user/mdb-esp32-cashless/Docker"    # dir containing docker-compose.yml on the server
PROD_STORAGE_DIR="$PROD_DIR/volumes/storage"       # storage root on the server (product-images lives under it)
DEV_SUPABASE_URL="http://127.0.0.1:54321"          # local Storage API base
# No DB connection string needed: the dev DB container is resolved from
# Docker/supabase/config.toml `project_id` → container `supabase_db_<project_id>`.
# SERVICE_ROLE_KEY is read at runtime from `supabase status -o env`.
```

CLI flags: `--yes` (skip confirmation, for unattended/cron), `--clean` (also delete the image cache afterwards), `--keep-dumps` (don't delete SQL dumps), `--skip-images` (DB only, fast refresh).

## Flow (5 phases)

### Phase 0 — Preflight & safety

1. **Tool check:** verify `docker`, `rsync`, `ssh`, `curl`, `supabase` are on PATH; abort with a clear message naming any missing one.
2. Load `sync-prod-to-dev.env`; abort if missing.
3. **Resolve the dev DB container (this is the dev guard):**
   ```sh
   PROJECT_ID=$(grep -E '^\s*project_id' Docker/supabase/config.toml | head -n1 | cut -d'"' -f2)
   DEV_DB_CONTAINER="supabase_db_${PROJECT_ID}"
   docker ps --format '{{.Names}}' | grep -qx "$DEV_DB_CONTAINER"   # must exist & be running
   ```
   This is inherently local — a local Docker container by construction — so the destructive steps **cannot** target a remote DB. If the container isn't running, abort telling the user to run `supabase start`.
4. **Connectivity:** `docker exec "$DEV_DB_CONTAINER" pg_isready -U postgres` must succeed.
5. **Schema currency:** run `supabase migration up` (from `Docker/supabase/`) — non-destructive, applies only pending migrations so the dev `public` schema ⊇ prod's before we load prod data.
6. **Confirmation prompt:** "This REPLACES all data in your local dev DB (container `$DEV_DB_CONTAINER`) with production data. Continue? [y/N]" — skipped with `--yes`.

### Phase 1 — Dump prod (read-only, via SSH)

Run `pg_dump` **inside the prod `db` container**, stream stdout to local files in `tmp/sync/`:

```sh
# public business data (all tables + sequence setvals)
ssh "$PROD_SSH" "cd '$PROD_DIR' && docker compose exec -T db \
  pg_dump -U postgres -d postgres --data-only --no-owner --no-privileges \
  --schema=public 2>/dev/null" > tmp/sync/public.sql

# surgical auth: only the two tables needed for login
ssh "$PROD_SSH" "cd '$PROD_DIR' && docker compose exec -T db \
  pg_dump -U postgres -d postgres --data-only --no-owner --no-privileges \
  --table=auth.users --table=auth.identities 2>/dev/null" > tmp/sync/auth.sql
```

- `--data-only` ⇒ no DDL ⇒ the 15→17 version gap is irrelevant (rows only). pg_dump prepends `SELECT pg_catalog.set_config('search_path','',false)`, emits fully-qualified `COPY public.<t> …` / `COPY auth.<t> …` blocks with inline data + `\.` terminators, and `setval(...)` for owned sequences. It emits **no** `BEGIN/COMMIT`, so it nests cleanly inside our wrapper transaction.
- `-T` (no TTY) keeps stdout binary-clean; `2>/dev/null` on the remote side prevents a stray compose/warning line from corrupting the dump.
- **Dump sanity check:** after each dump, assert the file is non-empty and its first non-blank line starts with `SET`, `SELECT`, or `--`; abort otherwise (catches an SSH/compose error that produced garbage instead of SQL). Prod is only ever read.

### Phase 2 — Fetch product-image files

**Storage file-backend layout** (confirmed in `PROD.md` §10): objects are stored on disk as `…/<bucket>/<object_name>/<version-uuid>` — i.e. the object name (`<product_id>.png`) is a **directory**, and the bytes live in a version-named file *inside* it.

1. Discover the bucket dir on the server (don't hard-code the prefix):
   ```sh
   IMG_DIR=$(ssh "$PROD_SSH" "find '$PROD_STORAGE_DIR' -type d -name product-images | head -n1")
   ```
2. Pull the subtree down (nested `<name>/<version>` structure preserved):
   ```sh
   rsync -a -e ssh "$PROD_SSH:$IMG_DIR/" tmp/sync/product-images/
   ```
   Plain `-a` is sufficient — we do **not** need xattrs, because the dev Storage API regenerates its own metadata on upload (Phase 4).
3. `--skip-images` skips this phase.

### Phase 3 — Restore into dev (single atomic transaction)

The script computes the public truncate list dynamically, assembles the wrapper, and streams it into the dev DB container in one psql session:

```sh
PUBLIC_TABLES=$(docker exec "$DEV_DB_CONTAINER" psql -tA -U postgres -d postgres -c \
  "SELECT string_agg(format('%I.%I', schemaname, tablename), ', ') FROM pg_tables WHERE schemaname='public'")

{
  echo "BEGIN;"
  echo "SET session_replication_role = replica;"   # disables triggers (incl. on_auth_user_created) + FK enforcement
  echo "TRUNCATE ${PUBLIC_TABLES}, auth.users RESTART IDENTITY CASCADE;"
  cat tmp/sync/auth.sql       # auth.users, auth.identities
  cat tmp/sync/public.sql     # all public data + sequence setvals
  echo "SET session_replication_role = default;"
  echo "COMMIT;"
} | docker exec -i "$DEV_DB_CONTAINER" psql -v ON_ERROR_STOP=1 -U postgres -d postgres
```

Why this is correct and safe:
- `session_replication_role = replica` turns off the normally-enabled `on_auth_user_created` trigger (otherwise loading `auth.users` would auto-insert `public.users` rows and collide with the dumped `public.users` data — the seed relies on that trigger, confirming the collision is real) and removes FK ordering constraints during the COPY load. Loading `auth.sql` before `public.sql` is therefore safe regardless.
- `-v ON_ERROR_STOP=1` + the wrapping `BEGIN/COMMIT` ⇒ **any error aborts before COMMIT ⇒ full ROLLBACK ⇒ dev data untouched.**
- **TRUNCATE … CASCADE blast radius (intended):** `TRUNCATE auth.users … CASCADE` cascades to every table FK-referencing `auth.users` — all `auth.*` internals (`identities`, `sessions`, `refresh_tokens`, `mfa_*`, `one_time_tokens`, `sso_*`, `saml_*`) and the many `public.*` tables with an owner/user FK. Clearing stale auth-internal state and sessions is desired. It does **not** reach `storage.objects` (no FK to `auth.users`; RLS-only), which is why Phase 4 rebuilds storage separately. Note `session_replication_role=replica` does *not* alter CASCADE traversal (it only gates trigger/FK-check firing on row DML) — the explicit full `public` list is what guarantees business tables not FK-linked to `users` (products, sales, …) are also cleared.
- Computing the public list from the dev catalog means **future tables are included automatically** — no maintenance when migrations add tables.
- The restore runs as superuser `postgres` inside the container, so RLS never blocks the load.

### Phase 4 — Re-ingest product images through the dev Storage API

Read the dev service-role key once:
```sh
SERVICE_ROLE_KEY=$(supabase status -o env | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p')
```

For each object directory under `tmp/sync/product-images/`, the object name is the **directory name** and the bytes are the newest file inside it:

```sh
find tmp/sync/product-images -mindepth 1 -maxdepth 1 -type d | while read -r namedir; do
  OBJECT_NAME=$(basename "$namedir")                       # e.g. <product_id>.png  (matches products.image_path)
  FILE=$(ls -t "$namedir" | head -n1); FILE="$namedir/$FILE"  # newest version file
  MIME=...   # from OBJECT_NAME extension: png→image/png, jpg/jpeg→image/jpeg, webp→image/webp
  curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "$DEV_SUPABASE_URL/storage/v1/object/product-images/$OBJECT_NAME" \
    -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H "Content-Type: $MIME" \
    -H "x-upsert: true" \                                  # idempotent re-runs
    --data-binary "@$FILE"
  # log (don't abort) on non-2xx — see caveats (2MiB / mime-allowlist on the dev bucket)
done
```

- The Storage API creates the `storage.objects` row **and** the on-disk file with correct metadata/xattrs ⇒ the "500 ENODATA on public URL" failure mode is impossible by construction, and copying prod's `storage.objects` is unnecessary.
- Object name = `products.image_path` (`{product_id}.{ext}`), loaded in Phase 3, so frontend `getProductImageUrl()` URLs resolve.
- The `product-images` bucket already exists in dev (from `config.toml`); no bucket creation needed.
- Upload failures are **logged, not fatal** (one oversized/odd-mime image must not abort the whole sync). Phase 5's count check surfaces any gap.

### Phase 5 — Verify & cleanup

1. Print sanity counts from the dev container (`docker exec … psql -tA -c 'select count(*) …'`) for: `auth.users`, `companies`, `embeddeds`, `vendingMachine`, `products`, `sales`, and `storage.objects` (product-images) — compared against the local image directory count. This comparison is **informational**, not a hard failure: `storage.objects` < local-dir count is expected when Phase 4 logged-and-skipped an oversized or odd-MIME image (the gap equals the number of skipped uploads).
2. Delete `tmp/sync/*.sql` (unless `--keep-dumps`). Keep `tmp/sync/product-images/` by default for faster re-runs; `--clean` removes it too.
3. Print: "Done. Log into dev at http://localhost:3000 with your production credentials."

## Repeatability / scheduling

- Primary mode is manual: `./scripts/sync-prod-to-dev.sh`. Prerequisite: `supabase start` is running.
- For periodic refreshes, the script header / `scripts/README.md` documents a commented example (cron + macOS launchd) invoking it with `--yes`. Not enabled by default, because a refresh overwrites local state and should be intentional.

## Assumptions & accepted risks

- **Auth column skew (both `auth.users` *and* `auth.identities`):** if prod's GoTrue is *newer* than the dev CLI's GoTrue and either table gained a column the dev table lacks, the `COPY` fails. Mitigation: keep the CLI updated so dev ⊇ prod (the common case). **Fallback** (documented as a commented variant in the script): replace each `--table=` dump with a `\copy (SELECT <explicit stable column list>) TO STDOUT` and a matching `\copy <table>(<same columns>) FROM STDIN` on load, so only mutually-present columns move.
  - `auth.users` stable column list (aligned with `seed.sql`'s known-good NOT-NULL-sensitive set): `instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, is_super_admin, created_at, updated_at, phone, confirmation_token, recovery_token, email_change_token_new, email_change_token_current, email_change, reauthentication_token, phone_change, phone_change_token, is_sso_user, is_anonymous`.
  - `auth.identities` stable column list: `id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at, email`.
- **Dev schema must be ≥ prod schema** for the `public` load (Phase 0 step 5 applies pending migrations). Two prod-ahead failure modes, both surfaced clearly by the transaction error and both resolved by pulling the missing migration into the repo first:
  1. *Prod has an extra column* on a shared table → `COPY` references an unknown column → load fails, rolls back.
  2. *Prod has an entire table* not yet in the repo's migrations → `public.sql` contains `COPY public.<unknown_table>` → load fails, rolls back. (The dynamic truncate list, built from the dev catalog, also wouldn't include it.)
- **Real secrets land on the dev machine:** `embeddeds.passkey`, MQTT credentials, `companies.anthropic_api_key`, `api_keys.key_hash`. Acceptable: the developer's own data on their own machine. (`embeddeds.mqtt_host`/`port` point at the prod broker and are simply inert in dev.)
- **Sessions are dropped:** the developer logs in once after a refresh. Intended.
- **Storage bucket limits:** the dev `product-images` bucket enforces `png/jpeg/webp` + 2 MiB (`config.toml`). A prod object exceeding either fails its upload (logged, non-fatal).
- **Realtime:** TRUNCATE/COPY during the load may emit logical-replication events to any connected dev client. Harmless (no consumer cares mid-refresh).

## Verification (acceptance)

1. Run the script against a running local dev stack; it completes without error and prints non-zero counts matching prod magnitudes.
2. Log into the dev frontend with a **production** email + password → succeeds and shows that user's real company data.
3. A product with an image in prod shows its image in dev (URL 200, not 404).
4. Re-running the script is idempotent (no duplicate rows; image upload upserts).
5. With the dev container not running (or renamed), the script refuses before touching any data.
6. Forcing a SQL error mid-restore leaves the previous dev data intact (transaction rolled back).

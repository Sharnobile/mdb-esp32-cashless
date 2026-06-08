# Prod → Test Data Sync (refresh the test server with production data)

**Date**: 2026-06-08
**Status**: Design — pending user review
**Scope**: New repo tooling under `scripts/` — a repeatable script that refreshes the **test server's database + product images** with **production data**. No application code, no migrations, no backend behaviour change. Sibling to `scripts/sync-prod-to-dev.sh`; see that design at `docs/superpowers/specs/2026-05-29-prod-to-dev-data-sync-design.md`.

## Problem

The team runs a **test server** that is a faithful copy of production: the same `Docker/docker-compose.yml` stack, deployed identically, reachable under a different domain. We want a **repeatable, safe** way to refresh the test server with current production data so test mirrors reality — and such that **logging into test with real production credentials still works** afterwards (the full user/company/membership graph comes over, so RLS shows exactly what each prod user sees).

The existing `sync-prod-to-dev.sh` already does this for the **local Supabase CLI dev DB**. This is the same operation pointed at a **full prod-like Docker deployment** instead of a local CLI container. That single change removes the dev script's core safety property — it could *only ever* address a local container — so the design re-establishes safety with an explicit, layered guard.

## Topology (the two environments)

| | Production | Test |
|---|---|---|
| Stack | `Docker/docker-compose.yml` (full self-hosted Supabase) | **identical** `Docker/docker-compose.yml` |
| Postgres | `supabase/postgres:15.8.1.060` (**major 15**) | **same image, major 15** |
| DB reachability | loopback only on the server (`127.0.0.1`/`::1` :5432) | same |
| Storage files | `Docker/volumes/storage/` (file backend, `STORAGE_BACKEND=file`) | same |
| Kong / API | `KONG_HTTP_PORT` (default 8000) | same, different external domain |
| Auth | GoTrue, `auth` schema | **same GoTrue image** |
| Secrets (`Docker/.env`) | prod's own `JWT_SECRET`/`ANON_KEY`/`SERVICE_ROLE_KEY`/… | test's **own, distinct** secrets |
| Domain | `SUPABASE_PUBLIC_URL` = prod domain | `SUPABASE_PUBLIC_URL` = **test domain** |

Two facts drive the design:

1. **Prod and test run the byte-identical stack** (same Postgres major, same GoTrue, same Storage). There is **no version gap** (unlike dev's 15→17), so a **data-only** dump/restore into the already-correct test schema is clean and the `auth.users`/`auth.identities` column layout is guaranteed compatible. This is *simpler* than the dev case.
2. **The test schema is owned by the test server's own deploy** (`Docker/update.sh` applies migrations from `main`). We must **not** drop/recreate it or run migrations from this script. We refresh **row data inside the existing tables** and assume — and verify — that test is deployed at prod's migration level.

## Decisions (captured during brainstorming)

1. **Where it runs — on the test box.** The script lives in the repo checkout on the test server and runs there. The only thing crossing SSH is a **read-only pull from prod** (`pg_dump` + `rsync`). Every destructive step — truncate, restore, image upload — is **local to test**, addressed through test's own `Docker/` compose stack and `http://localhost:${KONG_HTTP_PORT}`. The script cannot name a different database: the restore target is always "this machine's own `db` service."
2. **Login model — clone prod auth.** Copy `auth.users` + `auth.identities` + the entire `public` graph so an operator logs into test with real prod credentials and RLS is internally consistent. Test keeps its **own** `JWT_SECRET`/keys (we touch DB rows only, never `Docker/.env`); prod's bcrypt `encrypted_password` hashes are portable, so password login works regardless of the differing JWT secret.
3. **Source — SSH + `pg_dump` on prod.** SSH to the prod host, run `pg_dump` inside the prod `db` container, stream the dump down to the test box. Prod is **read-only** throughout.
4. **Storage — Storage API re-ingest.** `product-images` files are pulled from prod with `rsync`, then re-uploaded through **test's own Storage REST API** with `x-upsert: true`. This mirrors the proven dev path and sidesteps the xattr/`ENODATA`-on-public-URL pitfall of a raw volume copy (see `project_server_migration` history). `storage.objects`/`storage.buckets` rows are **not** copied — the API recreates them. **Firmware binaries are not copied.**
5. **Migration skew → abort.** If prod and test are at different migration versions (by `max(name)` or `count(*)` of `public._migrations`), preflight hard-stops with instructions to deploy test to prod's version first. This catches the common version-drift case before any write; a residual true schema skew is still caught by the atomic-transaction rollback (Phase 3), so the operation is never destructive on mismatch.
6. **Stale test images → leave them (upsert-only).** Only prod's images are added/overwritten. Any test image not in prod survives as an invisible orphan (after the DB is replaced from prod, no `products.image_path` references it; the frontend only renders referenced objects). Matches the dev script exactly.

## Goals

- One command, run on the test box, refreshes the test DB + product images with production data, repeatably.
- After a refresh, an operator can log into the test frontend with a **production** email + password.
- All `public` business data mirrors prod; product images render (URLs resolve).
- The destructive load is **atomic** (single transaction) and **guarded** so it can never run against prod and never half-wipes test.
- Does **not** use `supabase db reset`; does **not** run migrations; does **not** modify prod.

## Non-goals

- **No** full cluster clone; **no** restore of `auth.sessions`, `auth.refresh_tokens`, MFA, or any non-`public` schema other than the two named auth tables.
- **No** firmware-binary copy; **no** `storage.objects` row copy from prod (the re-upload recreates them); **no** deletion of stale test images.
- **No** change to prod (read-only), to test's `Docker/.env`/secrets, to migrations, to edge functions, or to app code.
- **No** automatic scheduling by default — a refresh overwrites the test DB and is a deliberate manual action (commented cron example provided).

## Components

| File | Purpose | Git |
|---|---|---|
| `scripts/sync-prod-to-test.sh` | Orchestrator (bash, `set -euo pipefail`, portable to bash 3.2) | committed |
| `scripts/sync-prod-to-test.env.example` | Config template with documented keys | committed |
| `scripts/sync-prod-to-test.env` | The operator's real values (prod SSH/dir, expected test domain) | **gitignored** |
| `tmp/sync-test/` | Work dir on the test box: SQL dumps + image cache | **gitignored** |
| `.gitignore` | add `tmp/sync-test/` and `scripts/sync-prod-to-test.env` | edited |
| `scripts/README.md` | add a `sync-prod-to-test.sh` section (prerequisites, run, safety, scheduling) | edited |

Pure helpers (`mime_for`, `dump_looks_like_sql`, `build_truncate_stmt`, plus new `read_env_value` and `domain_in_url` helpers) are unit-tested in a **new, separate** file `scripts/test/test-sync-test-helpers.sh` that sources only `sync-prod-to-test.sh` — it must not collide with the existing `scripts/test/test-sync-helpers.sh` (which sources `sync-prod-to-dev.sh`). The three shared-name helpers (`mime_for`, `dump_looks_like_sql`, `build_truncate_stmt`) are **intentionally copied** into the standalone sibling script rather than factored into a shared lib, keeping each `sync-*.sh` self-contained (the dev script's stated design); no single test file sources both scripts, avoiding a silent redefinition. This matches the dev script's split between unit-tested pure functions and `--dry-run`-verified integration phases.

### Configuration keys (`sync-prod-to-test.env`)

```sh
PROD_SSH="user@prod-host"                          # ssh target or ~/.ssh/config alias (read-only source)
PROD_DIR="/home/user/mdb-esp32-cashless/Docker"    # dir containing docker-compose.yml on prod
PROD_STORAGE_DIR="$PROD_DIR/volumes/storage"       # storage root on prod (product-images lives under it)
TEST_EXPECTED_DOMAIN="test.vmflow.example"         # MUST appear in THIS box's Docker/.env SUPABASE_PUBLIC_URL
```

**Derived, not configured** (so the destructive target can never be mis-pointed):
- `TEST_DIR = <repo-root>/Docker` — the compose dir on this box (where the script lives).
- `SERVICE_ROLE_KEY`, `SUPABASE_PUBLIC_URL`, `KONG_HTTP_PORT` — read at runtime from `<repo-root>/Docker/.env`.
- `TEST_SUPABASE_URL = http://localhost:${KONG_HTTP_PORT:-8000}` — local Storage API base (avoids TLS/domain).

**`.env` parsing contract (mandatory).** Read each key with a per-key `grep` + `cut`, **never** `source $TEST_DIR/.env`. Unlike the dev script's hand-written, shell-quoted `sync-prod-to-dev.env`, `$TEST_DIR/.env` is the **full upstream Supabase env file**: it ships unquoted values containing spaces (e.g. `STUDIO_DEFAULT_ORGANIZATION=Default Organization`) and may hold multi-line PEM blocks (e.g. `APNS_PRIVATE_KEY`) — `source` mis-parses both. Use the same approach `Docker/update.sh` already uses, e.g. `grep -E '^SERVICE_ROLE_KEY=' "$TEST_DIR/.env" | head -1 | cut -d= -f2-`, then strip any surrounding quotes and a trailing `\r`. This is parsed identically on the prod side (`$PROD_DIR/.env` over SSH) for the guard's URL comparison. A `read_env_value` helper encapsulates this and is unit-tested.

CLI flags: `--yes` (skip confirmation, for unattended/cron), `--dry-run` (preview; no writes), `--skip-images` (DB only), `--keep-dumps` (don't delete SQL dumps), `--clean` (also delete the image cache afterwards), `-h/--help`.

## Flow (6 phases)

### Phase 0 — Preflight & the layered guard

1. **Tool check:** verify `docker`, `ssh`, `rsync`, `curl` are on PATH; abort naming any missing one. (No `supabase` CLI dependency — this is a plain Docker stack.)
2. Load `sync-prod-to-test.env`; abort if missing. Require `PROD_SSH`, `PROD_DIR`, `PROD_STORAGE_DIR`, `TEST_EXPECTED_DOMAIN`.
3. **Resolve the local stack:** `TEST_DIR = <repo-root>/Docker`; assert `$TEST_DIR/.env` and `$TEST_DIR/docker-compose.yml` exist. Read `SUPABASE_PUBLIC_URL`, `SERVICE_ROLE_KEY`, `KONG_HTTP_PORT` from `$TEST_DIR/.env`.
4. **Guard step A — this box self-identifies as test:** the local `SUPABASE_PUBLIC_URL` **must contain** `TEST_EXPECTED_DOMAIN` (substring containment by design — the operator sets the value precisely enough for their domain). If the script is ever run on the prod box (whose `.env` carries the prod domain), this fails → abort. *This is the primary guard;* Guard B (source ≠ target) is the backstop should a box be genuinely mis-provisioned with the wrong domain.
5. **Guard step B — source ≠ target:** SSH to prod, read prod's `SUPABASE_PUBLIC_URL` from `$PROD_DIR/.env`; assert it **differs** from the local one. Prevents dump-and-restore-into-self if `PROD_*` is misconfigured to point back at this box.
6. **Guard step C — migration parity:** read both `max(name)` **and** `count(*)` from `public._migrations` on **both** prod (over SSH, inside its `db` container) and test (local `db` container). If either differs → **abort** with: "test is at migration X (n applied), prod at Y (m applied) — deploy/pull test to prod's version first, then re-run." `_migrations.name` is the migration filename (`text primary key`); filename-timestamp order equals lexical order, so `max(name)` is a sound "latest applied" signal, and the `count(*)` pairing also catches a divergent set below an equal max (one side skipped/failed a migration `update.sh` recorded as not-applied). This **detects the common version-drift case**; it is not a full schema diff — a true column/table skew that slips past it is still caught by Phase 3's atomic transaction (rollback, test untouched). A `max(name)` mismatch where **test is *ahead*** of prod also aborts (conservative false-positive: an older-prod→newer-test data load would often succeed, but we refuse rather than guess).
7. **Connectivity:** `docker compose -f $TEST_DIR/... exec -T db pg_isready -U postgres` (local) must succeed.
8. **Confirmation prompt** (skipped with `--yes`): print **source → target** explicitly —
   ```
   This REPLACES ALL DATA in the TEST database with production data.
     source (read-only): <PROD_SSH>  <prod SUPABASE_PUBLIC_URL>
     target (this box) : <TEST_DIR>  <test SUPABASE_PUBLIC_URL>
   Continue? [y/N]
   ```

> All destructive steps run **after** the guard and **only** against the local compose `db` service. The script never accepts a remote DB address for the restore.

### Phase 1 — Dump prod (read-only, via SSH)

Run `pg_dump` **inside the prod `db` container**, stream stdout to local files in `tmp/sync-test/`:

```sh
# public business data (all tables + sequence setvals)
ssh "$PROD_SSH" "cd '$PROD_DIR' && docker compose exec -T db \
  pg_dump -U postgres -d postgres --data-only --no-owner --no-privileges \
  --schema=public 2>/dev/null" > tmp/sync-test/public.sql

# surgical auth: only the two tables needed for login
ssh "$PROD_SSH" "cd '$PROD_DIR' && docker compose exec -T db \
  pg_dump -U postgres -d postgres --data-only --no-owner --no-privileges \
  --table=auth.users --table=auth.identities 2>/dev/null" > tmp/sync-test/auth.sql
```

- `--data-only` ⇒ no DDL ⇒ rows only; the prepended `set_config('search_path','',false)` + fully-qualified `COPY public.<t>` / `COPY auth.<t>` blocks with inline data + `setval(...)` nest cleanly inside the wrapper transaction (pg_dump emits no `BEGIN/COMMIT`).
- `-T` (no TTY) keeps stdout binary-clean; `2>/dev/null` on the remote prevents a stray compose/warning line from corrupting the dump.
- **Dump sanity check:** after each dump, assert the file is non-empty and its first non-blank line begins with `SET`, `SELECT`, or `--`; abort otherwise (catches an SSH/compose error that produced garbage). Prod is only ever read.

### Phase 2 — Fetch product-image files (read-only, via SSH)

Storage file-backend layout: objects live on disk as `…/<bucket>/<object_name>/<version-uuid>` — the object name (`<product_id>.png`) is a **directory** holding a version-named file.

```sh
IMG_DIR=$(ssh "$PROD_SSH" "find '$PROD_STORAGE_DIR' -type d -name product-images | head -n1")
rsync -a -e ssh "$PROD_SSH:$IMG_DIR/" tmp/sync-test/product-images/
```

Plain `-a` is sufficient — the Storage API regenerates its own metadata on upload (Phase 4), so xattrs are not needed. `--skip-images` skips this phase. A missing `product-images` dir on prod logs a warning and skips (not fatal).

### Phase 3 — Restore into test (single atomic transaction, local)

Compute the public truncate list from **test's own** catalog, assemble the wrapper, stream it into the local `db` container in one psql session:

```sh
PUBLIC_TABLES=$(docker compose exec -T db psql -tA -U postgres -d postgres -c \
  "SELECT string_agg(format('%I.%I', schemaname, tablename), ', ') FROM pg_tables WHERE schemaname='public'")

{
  echo "BEGIN;"
  echo "SET session_replication_role = replica;"   # disables triggers (incl. on_auth_user_created) + FK enforcement
  echo "TRUNCATE ${PUBLIC_TABLES}, auth.users CASCADE;"
  cat tmp/sync-test/auth.sql       # auth.users, auth.identities
  cat tmp/sync-test/public.sql     # all public data + sequence setvals
  echo "SET session_replication_role = default;"
  echo "COMMIT;"
} | docker compose exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres
```

(`docker compose exec` is run from `$TEST_DIR` so compose resolves the `db` service to its container — no hard-coded container name. The `db` service sets no `container_name`, so the compose-default name is used; resolving via the service avoids guessing it.)

Why this is correct and safe (identical reasoning to the dev script):
- `session_replication_role = replica` turns off the normally-enabled `on_auth_user_created` trigger (otherwise loading `auth.users` would auto-insert colliding `public.users` rows) and removes FK ordering constraints during COPY, so loading `auth.sql` before `public.sql` is safe.
- `-v ON_ERROR_STOP=1` + the wrapping `BEGIN/COMMIT` ⇒ **any error aborts before COMMIT ⇒ full ROLLBACK ⇒ test data untouched.**
- **TRUNCATE … CASCADE blast radius (intended):** `TRUNCATE auth.users … CASCADE` cascades to every table FK-referencing `auth.users` — all `auth.*` internals (`identities`, `sessions`, `refresh_tokens`, `mfa_*`, `one_time_tokens`, `sso_*`, `saml_*`) and the `public.*` tables with an owner/user FK. Clearing stale auth-internal state and sessions is desired. It does **not** reach `storage.objects` (no FK to `auth.users`), which is why Phase 4 rebuilds storage separately. `session_replication_role=replica` does not alter CASCADE traversal; the explicit full `public` list guarantees business tables not FK-linked to `users` (products, sales, …) are also cleared.
- The public list is computed from test's catalog, so future tables are included automatically. (Phase 0's migration-parity check guarantees test's catalog matches prod's dump.)
- **No `RESTART IDENTITY`** in the TRUNCATE (reuse the dev script's `build_truncate_stmt` verbatim): `CASCADE` would otherwise try to reset auth-owned sequences the non-superuser `postgres` role cannot, and public sequence values are already restored by the dump's `setval()`. Follow the **dev *script***, not the dev *spec* (the 2026-05-29 spec text shows `RESTART IDENTITY`, but the proven script deliberately omits it — the script is authoritative).
- The restore runs as superuser `postgres` inside the container, so RLS never blocks the load.

### Phase 4 — Re-ingest product images through test's Storage API (local)

```sh
# SERVICE_ROLE_KEY read from $TEST_DIR/.env in Phase 0
find tmp/sync-test/product-images -mindepth 1 -maxdepth 1 -type d | while read -r namedir; do
  OBJECT_NAME=$(basename "$namedir")                          # <product_id>.png — matches products.image_path
  FILE=$(ls -t "$namedir" | head -n1); FILE="$namedir/$FILE"  # newest version file
  MIME=...   # png→image/png, jpg/jpeg→image/jpeg, webp→image/webp, else application/octet-stream
  curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "$TEST_SUPABASE_URL/storage/v1/object/product-images/$OBJECT_NAME" \
    -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H "Content-Type: $MIME" \
    -H "x-upsert: true" \
    --data-binary "@$FILE"
  # log (don't abort) on non-2xx
done
```

- The Storage API creates the `storage.objects` row **and** the on-disk file with correct metadata/xattrs ⇒ the "500 `ENODATA` on public URL" failure mode is impossible by construction; copying prod's `storage.objects` is unnecessary.
- Object name = `products.image_path` (`{product_id}.{ext}`), loaded in Phase 3, so frontend `getProductImageUrl()` URLs resolve.
- The `product-images` bucket already exists on test (created by migration `20260301100000_product_images.sql`, applied by test's own deploy — *guaranteed present by Guard C's parity check*); no bucket creation needed.
- **Upsert-only:** prod images are added/overwritten; test images not in prod are left as invisible orphans (decision 6).
- Upload failures are **logged, not fatal** (one oversized/odd-MIME image must not abort the sync). Phase 5's count check surfaces any gap.

### Phase 5 — Verify & cleanup (local)

1. Print sanity counts from the local `db` container for: `auth.users`, `companies`, `embeddeds`, `vendingMachine`, `products`, `sales`, and `storage.objects` (product-images), compared against the local image-directory count. The image comparison is **informational** (a `storage.objects` count below the local-dir count equals the number of logged-and-skipped uploads).
2. Delete `tmp/sync-test/*.sql` unless `--keep-dumps`. Keep `tmp/sync-test/product-images/` by default for faster re-runs; `--clean` removes it too.
3. Print: "Done. Log into the test frontend (<test SUPABASE_PUBLIC_URL>) with your production credentials."

## Repeatability / scheduling

- Primary mode is manual: `./scripts/sync-prod-to-test.sh`, run on the test box.
- For periodic refreshes, `scripts/README.md` documents a commented cron example invoking it with `--yes`. Not enabled by default, because a refresh overwrites the test DB.

## Assumptions & accepted risks

- **Test must be deployed at prod's migration level.** Enforced by Phase 0's parity check (abort on mismatch). Because prod and test run the identical GoTrue/Storage/Postgres images, there is **no auth column skew** (unlike the dev case) once migrations match.
- **SSH access:** the test box must have a (read-only-capable) SSH key authorised on the prod host. Prod is only ever read (`pg_dump` + `rsync` + reading `$PROD_DIR/.env`).
- **Real secrets land in the test DB:** `embeddeds.passkey`, MQTT credentials, `companies.anthropic_api_key`, `api_keys.key_hash`. Acceptable — test is the team's own infra. `embeddeds.mqtt_host`/`port` point at the **prod** broker and are inert on test (test field devices, if any, use the test broker via their own NVS config).
- **Test keeps its own secrets.** The script never touches `$TEST_DIR/.env`; test's `JWT_SECRET`/`ANON_KEY`/`SERVICE_ROLE_KEY` are unchanged. Sessions are dropped (TRUNCATE auth.users CASCADE) — operators re-login; prod password hashes are portable so prod credentials work.
- **Stale test images** not present in prod survive as invisible orphans (decision 6).
- **Storage bucket limits:** the `product-images` bucket enforces `png/jpeg/webp` + 2 MiB. Prod objects already satisfy these (identical limits on prod), so all prod images upload; an out-of-policy object would log-and-skip (non-fatal).
- **`public._migrations` is replaced with prod's rows.** `--schema=public` dumps every public table including `_migrations`; Phase 3 truncates it (it's in the dynamic list) and reloads prod's history. After a sync, test's `_migrations` shows prod's applied-migration list — harmless, because Guard C just confirmed they were identical and the table is only read by `update.sh` on the next deploy. (The dev script has the same behaviour.)
- **Realtime:** TRUNCATE/COPY during the load may emit logical-replication events to any connected test client. Harmless mid-refresh.
- **Frontend connections during a refresh** briefly see a partially-empty DB only within the transaction window; the atomic COMMIT flips it. Acceptable for a test environment; run during a quiet window if desired.

## Verification (acceptance)

1. Run on the test box against a running test stack at prod's migration level; completes without error and prints non-zero counts matching prod magnitudes.
2. Log into the test frontend with a **production** email + password → succeeds and shows that user's real company data.
3. A product with an image in prod shows its image on test (URL 200, not 404).
4. Re-running is idempotent (no duplicate rows; image upload upserts).
5. **Guard A:** running the script on a box whose `Docker/.env` `SUPABASE_PUBLIC_URL` does **not** contain `TEST_EXPECTED_DOMAIN` (e.g. the prod box) refuses before touching any data.
6. **Guard C:** with test at a different migration version than prod, preflight aborts with the deploy-first message and writes nothing.
7. Forcing a SQL error mid-restore leaves the previous test data intact (transaction rolled back).
8. `--dry-run` performs the guard + parity checks and prints the exact `TRUNCATE` and planned actions, making no writes.

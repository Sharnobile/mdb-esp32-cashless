# Low-Stock Daily Push Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `/warehouse` page-load drain of `low_stock_notifications` with a per-company timed daily push, configurable via a new Settings card.

**Architecture:** Database-driven cron. `pg_cron` ticks every full hour and calls a SECURITY DEFINER dispatcher that selects companies whose configured local-time hour matches the current UTC tick and POSTs the existing `check-low-stock` edge function via `pg_net`. The edge function gains an optional `company_id` filter and a 24h `created_at` guardrail. Frontend gets a new admin-only Settings card with timezone + hour selects, and the page-load drain is removed.

**Tech Stack:** Postgres 15 (`supabase/postgres:15.8.1.060`), `pg_cron`, `pg_net`, Deno (edge function), Nuxt 4 + Vue 3 (composition API), TypeScript, `@nuxtjs/supabase`, shadcn-nuxt, TailwindCSS 4, `@nuxtjs/i18n`.

**Spec:** [docs/superpowers/specs/2026-05-28-low-stock-daily-push-design.md](../specs/2026-05-28-low-stock-daily-push-design.md)

**Verification model:** SQL behavior tested by manual `docker compose exec db psql` queries against a docker-compose stack. Edge function tested by `curl` against the running function. Frontend tested by manual smoke test against the Nuxt dev server. No new automated tests — this feature has no pure-function logic worth unit-testing in isolation; integration points dominate.

**Deploy order reminder** (from spec): (1) migration + `docker-compose.yml` change, (2) `update.sh` rerun on each installation, (3) frontend deploy. Skipping step 2 leaves the dispatcher silently no-op until the next `update.sh`.

---

## Conventions for this Plan

- **Migration timestamp:** `20260528120000` (most recent existing is `20260522120000`). If two implementers race, bump to the next free minute. Filename: `Docker/supabase/migrations/20260528120000_low_stock_daily_push.sql`.
- **Migration immutability:** From `feedback_migration_immutability.md` — once this migration ships and is committed to `main`, never edit it. Bugs get fixed in a follow-up migration with `CREATE OR REPLACE FUNCTION`. The `.githooks/pre-commit` blocks edits.
- **DB access pattern:** every interactive psql is `docker compose exec -T db psql -U postgres -d postgres`. Local-dev (`supabase start`) tests use `docker exec supabase_db_<project> psql -U postgres -d postgres` — but most of this plan operates on the prod-style compose stack because cron needs `shared_preload_libraries`.
- **Working directory:** unless otherwise stated, commands run from `/Users/lucienkerl/Development/mdb-esp32-cashless/Docker/` (for `docker compose`) or `/Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/` (for npm).
- **Commits:** one per task. Conventional Commits with `feat(low-stock-push)`, `chore(infra)`, `feat(settings)` scopes. Never bundle the migration commit with the frontend commit.
- **Hard rule:** **NEVER** run `supabase db reset`. Dev DB holds test data.

---

## File Structure

| File | Responsibility | New / Modify |
|---|---|---|
| `Docker/docker-compose.yml` | Postgres `db.command` array. Add `shared_preload_libraries=pg_cron,pg_net` and `cron.database_name=postgres`. | Modify |
| `Docker/supabase/migrations/20260528120000_low_stock_daily_push.sql` | Add `timezone` + `low_stock_notification_hour` columns to `companies`. Create extensions. Create `dispatch_low_stock_pushes()`. Schedule cron job (guarded). | Create |
| `Docker/setup.sh` | `ALTER DATABASE` calls for `app.settings.supabase_url` + `service_role_key`, placed after DB health-check, before migration run. Both code paths (existing-`.env` reuse path and fresh-`.env` path). | Modify |
| `Docker/update.sh` | Same `ALTER DATABASE` calls, after DB health-check, before migration apply. | Modify |
| `Docker/supabase/functions/check-low-stock/index.ts` | Read optional `company_id` from body, add `.gte('created_at', now-24h)` filter. | Modify |
| `management-frontend/app/pages/warehouse/index.vue` | Remove the `checkLowStockNotifications()` call in `loadWarehouseData()` and the destructured import. | Modify |
| `management-frontend/app/lib/timezones.ts` | Curated IANA timezone list for the select. | Create |
| `management-frontend/app/components/settings/LowStockCard.vue` | New settings card. Timezone select + hour select (incl. "Disabled"). Loads + saves `companies.timezone` + `companies.low_stock_notification_hour`. | Create |
| `management-frontend/app/pages/settings/index.vue` | Insert `<SettingsLowStockCard />` between `<SettingsAiKeyCard />` and `<SettingsStripeCard />`. | Modify |
| `management-frontend/i18n/locales/en.json` | New `settings.lowStock.*` keys. (Path: find actual location during Task 8 — repo uses `@nuxtjs/i18n`.) | Modify |
| `management-frontend/i18n/locales/de.json` | Same, German values. | Modify |

No new edge functions, no new tables, no MQTT changes, no firmware changes.

---

## Pre-flight

- [ ] **Step 0.1: Confirm baseline is clean**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git status
```

Expected: working tree clean OR only pre-existing changes (`M ios/NotificationService/Info.plist`, `M ios/VMflow/Resources/Info.plist`, `M ios/VMflow/Resources/Localizable.xcstrings`, untracked `ios/VMflow.xcodeproj/xcshareddata/`, untracked `tmp/`) that this plan never touches. If anything else is dirty, surface to the user before continuing.

- [ ] **Step 0.2: Confirm docker-compose stack is up and healthy**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker
docker compose ps
```

Expected: `db`, `kong`, `functions`, `frontend` all `running (healthy)` or `running`. If the stack is down, `docker compose up -d` and wait ~30 s.

- [ ] **Step 0.3: Confirm the current pg extensions before any change**

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT extname FROM pg_extension WHERE extname IN ('pg_cron','pg_net');"
```

Capture the output — if `pg_cron` already shows in the result then `shared_preload_libraries` is already configured by the image and Task 1 becomes a no-op (still record the change in `docker-compose.yml` defensively). If only `pg_net` shows or neither shows, Task 1 is required.

- [ ] **Step 0.4: Confirm the `check-low-stock` function is reachable**

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT id FROM public.low_stock_notifications WHERE sent_at IS NULL LIMIT 1;"
```

Expected: either zero rows or one row. Either is fine — Task 6's verification later will use the existing queue.

---

## Chunk 1: Database & Cron Foundation

This chunk lands the migration, the docker-compose change, and verifies cron actually fires. After this chunk the dispatcher runs hourly but does nothing useful yet (no companies have `low_stock_notification_hour` set, and the edge-function POST will still work without `company_id`).

### Task 1: Defensive `shared_preload_libraries` in docker-compose.yml

**Files:**
- Modify: `Docker/docker-compose.yml`

- [ ] **Step 1.1: Inspect the existing `db.command` array**

```bash
grep -n "command:" /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/docker-compose.yml | head -5
```

Locate the `db.command` array around line 456 (current head of file). The array currently ends with `"min_wal_size=512MB"` (line ~482).

- [ ] **Step 1.2: Append the preload + cron-db flags**

Edit `Docker/docker-compose.yml`. Inside the `db.command` array, before the closing `]`, add two new `-c` pairs. The final array tail should look like:

```yaml
        "-c",
        "min_wal_size=512MB",
        "-c",
        "shared_preload_libraries=pg_cron,pg_net",
        "-c",
        "cron.database_name=postgres"
      ]
```

Indentation must match the existing 8-space-then-`-c` style. No trailing comma on the last element. Do NOT replace existing entries; only append.

- [ ] **Step 1.3: Recreate the db container so the new flags take effect**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker
docker compose up -d db
```

Expected: `Recreating Docker-db-1` (or similar) message, then container becomes healthy in ~10 s. If it errors out with `FATAL: could not access file "$libdir/pg_cron"`, the image doesn't ship pg_cron — stop and surface to the user (the spec assumes the supabase image includes it).

- [ ] **Step 1.4: Verify the preload took effect**

```bash
docker compose exec -T db psql -U postgres -d postgres -c "SHOW shared_preload_libraries;"
```

Expected: the value contains `pg_cron` somewhere (and may contain other things the image auto-injects — that's fine).

```bash
docker compose exec -T db psql -U postgres -d postgres -c "SHOW cron.database_name;"
```

Expected: `postgres`.

- [ ] **Step 1.5: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/docker-compose.yml
git commit -m "$(cat <<'EOF'
chore(infra): preload pg_cron + pg_net in db container

Required for the low-stock-daily-push migration which creates a cron
schedule. Without shared_preload_libraries=pg_cron, CREATE EXTENSION
fails.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2: Migration — columns, extensions, dispatcher, schedule

**Files:**
- Create: `Docker/supabase/migrations/20260528120000_low_stock_daily_push.sql`

- [ ] **Step 2.1: Write the migration file**

Create `Docker/supabase/migrations/20260528120000_low_stock_daily_push.sql` with the full content below:

```sql
-- Low-stock daily push via pg_cron.
-- Spec: docs/superpowers/specs/2026-05-28-low-stock-daily-push-design.md
--
-- Adds two opt-in columns to `companies`, creates pg_cron + pg_net,
-- creates a dispatcher SECURITY DEFINER function, and schedules a
-- global hourly cron job that fires the dispatcher.
--
-- The cron scheduling is guarded so the migration applies cleanly on
-- environments where pg_cron is not in shared_preload_libraries
-- (local `supabase start` dev). On such environments the dispatcher
-- function and columns are still created; only the schedule itself is
-- skipped (with a NOTICE).

-- 1. Columns on companies ----------------------------------------------------
ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS timezone text NOT NULL DEFAULT 'Europe/Berlin';

ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS low_stock_notification_hour smallint
    CHECK (low_stock_notification_hour IS NULL
           OR (low_stock_notification_hour BETWEEN 0 AND 23));

COMMENT ON COLUMN public.companies.timezone IS
  'IANA timezone name used for low_stock_notification_hour. Default Europe/Berlin.';
COMMENT ON COLUMN public.companies.low_stock_notification_hour IS
  'Hour-of-day (0..23, local time per timezone) at which the daily low-stock push fires. NULL = disabled.';

-- 2. Extensions --------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- 3. Dispatcher function -----------------------------------------------------
CREATE OR REPLACE FUNCTION public.dispatch_low_stock_pushes()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_company record;
  v_url text := current_setting('app.settings.supabase_url', true);
  v_key text := current_setting('app.settings.service_role_key', true);
BEGIN
  IF v_url IS NULL OR v_url = '' OR v_key IS NULL OR v_key = '' THEN
    RAISE WARNING 'dispatch_low_stock_pushes: app.settings.supabase_url or service_role_key not set; skipping. Run Docker/update.sh to configure.';
    RETURN;
  END IF;

  FOR v_company IN
    SELECT id
    FROM public.companies
    WHERE low_stock_notification_hour IS NOT NULL
      AND low_stock_notification_hour
          = EXTRACT(HOUR FROM (now() AT TIME ZONE timezone))::smallint
  LOOP
    PERFORM net.http_post(
      url     := v_url || '/functions/v1/check-low-stock',
      headers := jsonb_build_object(
                   'Authorization', 'Bearer ' || v_key,
                   'Content-Type',  'application/json'),
      body    := jsonb_build_object('company_id', v_company.id)
    );
  END LOOP;
END $$;

COMMENT ON FUNCTION public.dispatch_low_stock_pushes IS
  'Called hourly by pg_cron. Selects companies whose configured local-time hour matches now, and POSTs check-low-stock per company. Reads supabase_url and service_role_key from app.settings.* (set by Docker/setup.sh / Docker/update.sh).';

-- 4. Cron schedule (guarded for environments without pg_cron) ----------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    -- Idempotent unschedule of any previous version
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'low_stock_daily_push') THEN
      PERFORM cron.unschedule('low_stock_daily_push');
    END IF;

    PERFORM cron.schedule(
      'low_stock_daily_push',
      '0 * * * *',
      $cron$SELECT public.dispatch_low_stock_pushes();$cron$
    );

    RAISE NOTICE 'low_stock_daily_push: scheduled hourly';
  ELSE
    RAISE WARNING 'pg_cron not installed; low_stock_daily_push not scheduled. Fix shared_preload_libraries and re-run migration, or invoke dispatch_low_stock_pushes() manually.';
  END IF;
END $$;
```

- [ ] **Step 2.2: Apply the migration to the docker-compose DB**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker
docker compose exec -T db psql -U postgres -d postgres \
  < supabase/migrations/20260528120000_low_stock_daily_push.sql
```

Expected output includes:
- `ALTER TABLE` x2
- `COMMENT` x2
- `CREATE EXTENSION` x2 (or `NOTICE: extension "..." already exists, skipping`)
- `CREATE FUNCTION`
- `COMMENT`
- `NOTICE: low_stock_daily_push: scheduled hourly`

If you see `WARNING: pg_cron not installed`, Task 1's preload didn't take — go back and fix.

- [ ] **Step 2.3: Verify the columns**

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
  "\d public.companies" | grep -E "timezone|low_stock_notification_hour"
```

Expected: two rows, one for each new column. `timezone` shows `not null default 'Europe/Berlin'::text`; `low_stock_notification_hour` shows `smallint` and the CHECK constraint mentioned.

- [ ] **Step 2.4: Verify the function and cron entry**

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT proname, prosecdef FROM pg_proc WHERE proname = 'dispatch_low_stock_pushes';"
```

Expected: one row, `prosecdef = t` (SECURITY DEFINER).

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT jobname, schedule, command FROM cron.job WHERE jobname = 'low_stock_daily_push';"
```

Expected: one row with `schedule = '0 * * * *'` and the dispatcher SELECT.

- [ ] **Step 2.5: Record migration as applied (manual since we ran it via psql, not the runner)**

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
  "INSERT INTO public._migrations (name) VALUES ('20260528120000_low_stock_daily_push.sql') ON CONFLICT DO NOTHING;"
```

Expected: `INSERT 0 1` on a fresh apply, `INSERT 0 0` if a prior attempt already recorded it. This prevents `update.sh` from trying to re-apply on the next run.

- [ ] **Step 2.6: Smoke-test the dispatcher with `app.settings.*` still unset**

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT public.dispatch_low_stock_pushes();"
```

Expected: a `WARNING: dispatch_low_stock_pushes: app.settings.supabase_url or service_role_key not set; skipping.` and `dispatch_low_stock_pushes` returns. Nothing in `net.http_request_queue` yet (since the function returned early). Verify:

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT count(*) FROM net.http_request_queue;"
```

Expected: `0` (or whatever the count was *before* this call — Task 6 verifies the queue *grows* after settings are configured).

- [ ] **Step 2.7: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/migrations/20260528120000_low_stock_daily_push.sql
git commit -m "$(cat <<'EOF'
feat(low-stock-push): add daily push schedule infrastructure

Adds companies.timezone + companies.low_stock_notification_hour
columns (both opt-in safe defaults), enables pg_cron + pg_net,
creates dispatch_low_stock_pushes() SECURITY DEFINER function, and
schedules a guarded hourly cron job.

App.settings.supabase_url and app.settings.service_role_key are read
by the dispatcher and must be set by Docker/setup.sh + update.sh in
the next commit. Until then the dispatcher logs a WARNING and no-ops.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 2: setup.sh / update.sh integration

This chunk wires the `app.settings.*` calls into both bootstrap scripts. After this chunk the dispatcher has all the configuration it needs to actually fire HTTP requests.

### Task 3: Inject `ALTER DATABASE` into `update.sh`

**Files:**
- Modify: `Docker/update.sh`

`update.sh` runs on every existing installation. It's the safer of the two scripts to modify first because it doesn't generate a new SERVICE_ROLE_KEY — it reads the existing one from `.env`.

- [ ] **Step 3.1: Read the relevant section**

```bash
sed -n '200,260p' /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/update.sh
```

Find the DB health-check (loops `pg_isready`) which finishes around line 240, immediately before `step "2/4 — Applying New Migrations"`. The `ALTER DATABASE` calls go there.

- [ ] **Step 3.2: Source SERVICE_ROLE_KEY from .env and run ALTER DATABASE**

After the DB-readiness loop ends and before the migration-state probe begins, insert:

```bash
# ─────────────────────────────────────────────────────────────
# Configure DB settings consumed by SECURITY DEFINER functions
# (e.g. public.dispatch_low_stock_pushes for low-stock cron).
# These are idempotent — re-running overwrites prior values.
# ─────────────────────────────────────────────────────────────
if [ -f .env ]; then
    # shellcheck disable=SC1091
    set -a; source ./.env; set +a
fi

if [ -n "${SERVICE_ROLE_KEY:-}" ]; then
    INTERNAL_SUPABASE_URL="http://kong:8000"
    docker compose exec -T db psql -U postgres -d postgres >/dev/null 2>&1 <<SQL
ALTER DATABASE postgres SET app.settings.supabase_url = '${INTERNAL_SUPABASE_URL}';
ALTER DATABASE postgres SET app.settings.service_role_key = '${SERVICE_ROLE_KEY}';
SQL
    success "Configured app.settings.supabase_url + app.settings.service_role_key"
else
    warn "SERVICE_ROLE_KEY not found in .env — skipping app.settings configuration"
    warn "Low-stock daily push will not fire until SERVICE_ROLE_KEY is set"
fi
```

Use the exact same `success` / `warn` helpers the surrounding code uses (they're already defined at the top of the script). Indentation: 4-space, matching the file.

- [ ] **Step 3.3: Quick lint check on the modified script**

```bash
bash -n /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/update.sh
```

Expected: no output (syntax OK). If `bash -n` reports an error, fix and retry.

- [ ] **Step 3.4: Dry-run the new section against the running DB**

Extract just the ALTER DATABASE block and run it manually to confirm:

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker
set -a; source ./.env; set +a
docker compose exec -T db psql -U postgres -d postgres <<SQL
ALTER DATABASE postgres SET app.settings.supabase_url = 'http://kong:8000';
ALTER DATABASE postgres SET app.settings.service_role_key = '${SERVICE_ROLE_KEY}';
SQL
```

Expected: two `ALTER DATABASE` confirmations. To verify it stuck:

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT name, setting FROM pg_db_role_setting r JOIN pg_database d ON r.setdatabase = d.oid CROSS JOIN LATERAL unnest(r.setconfig) AS setting WHERE d.datname = 'postgres' AND setting LIKE 'app.settings.%';"
```

Expected: two rows, one for each setting. The `service_role_key` value will be visible — that's fine in dev, the prod scripts wrap with `>/dev/null`.

- [ ] **Step 3.5: Re-run the dispatcher to confirm it now sees the settings**

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT public.dispatch_low_stock_pushes();"
```

Expected: no WARNING this time. `dispatch_low_stock_pushes` returns. `net.http_request_queue` may or may not have new rows depending on whether any company currently has `low_stock_notification_hour` set to the current Berlin hour — typically zero, since the column defaulted to NULL on every existing row.

- [ ] **Step 3.6: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/update.sh
git commit -m "$(cat <<'EOF'
chore(update): configure app.settings for low-stock push dispatcher

Adds ALTER DATABASE calls so dispatch_low_stock_pushes() can find the
internal Kong URL and the service-role key. Idempotent — re-runs on
every update.sh invocation, so a regenerated SERVICE_ROLE_KEY is
picked up automatically.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 4: Mirror the change in `setup.sh`

**Files:**
- Modify: `Docker/setup.sh`

`setup.sh` has TWO migration paths (the existing-`.env` reuse path starting around line 140, and the fresh-`.env` path starting around line 543). Both need the `ALTER DATABASE` calls.

- [ ] **Step 4.1: Add to the existing-.env reuse path**

Around line 155 (after `if [ "$DB_READY" = false ]; then error "..."; fi`, before `MIGRATION_DIR="supabase/migrations"`), insert:

```bash
        # ─────────────────────────────────────────────────────────────
        # Configure DB settings consumed by SECURITY DEFINER functions
        # ─────────────────────────────────────────────────────────────
        # shellcheck disable=SC1091
        set -a; source ./.env; set +a
        if [ -n "${SERVICE_ROLE_KEY:-}" ]; then
            docker compose exec -T db psql -U postgres -d postgres >/dev/null 2>&1 <<SQL
ALTER DATABASE postgres SET app.settings.supabase_url = 'http://kong:8000';
ALTER DATABASE postgres SET app.settings.service_role_key = '${SERVICE_ROLE_KEY}';
SQL
            success "Configured app.settings.* for low-stock push dispatcher"
        fi
```

Indentation matches the surrounding 8-space block (this is inside an `if`-branch one level deeper than `update.sh`).

- [ ] **Step 4.2: Add to the fresh-.env path**

Around line 563 (after `info "Waiting for Supabase initialization to complete..."; sleep 5`, before `MIGRATION_DIR="supabase/migrations"`), insert at 0-space indent (top level of the script):

```bash
# ─────────────────────────────────────────────────────────────
# Configure DB settings consumed by SECURITY DEFINER functions
# ─────────────────────────────────────────────────────────────
docker compose exec -T db psql -U postgres -d postgres >/dev/null 2>&1 <<SQL
ALTER DATABASE postgres SET app.settings.supabase_url = 'http://kong:8000';
ALTER DATABASE postgres SET app.settings.service_role_key = '${SERVICE_ROLE_KEY}';
SQL
success "Configured app.settings.* for low-stock push dispatcher"
```

In this branch `$SERVICE_ROLE_KEY` was just generated by line 323 (`generate_jwt`) and is already in the shell environment.

- [ ] **Step 4.3: Lint**

```bash
bash -n /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/setup.sh
```

Expected: no output.

- [ ] **Step 4.4: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/setup.sh
git commit -m "$(cat <<'EOF'
chore(setup): configure app.settings for low-stock push dispatcher

Mirrors the update.sh change in both setup.sh code paths (fresh-.env
generation and existing-.env reuse).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 3: Edge function

### Task 5: Extend `check-low-stock` with `company_id` filter and 24h guardrail

**Files:**
- Modify: `Docker/supabase/functions/check-low-stock/index.ts`

- [ ] **Step 5.1: Read the current function**

```bash
sed -n '40,60p' /Users/lucienkerl/Development/mdb-esp32-cashless/Docker/supabase/functions/check-low-stock/index.ts
```

Confirm lines 44–50 contain the existing query builder (`adminClient.from('low_stock_notifications').select(...).is('sent_at', null).order('created_at').limit(100)`).

- [ ] **Step 5.2: Replace the query block with the parametrized version**

In `Docker/supabase/functions/check-low-stock/index.ts`, the current block at lines 44-50:

```ts
    // Fetch unsent low-stock notifications
    const { data: notifications, error: fetchError } = await adminClient
      .from('low_stock_notifications')
      .select('id, company_id, product_name, current_quantity, min_quantity')
      .is('sent_at', null)
      .order('created_at')
      .limit(100)
```

Replace with:

```ts
    // Optional company_id filter — set by the pg_cron dispatcher so each
    // company gets its own push. Calls without a body keep the existing
    // "drain all" behavior (backward compat for older frontends).
    const contentLength = req.headers.get('content-length')
    const reqBody: Record<string, unknown> = contentLength && contentLength !== '0'
      ? await req.json().catch(() => ({}))
      : {}
    const filterCompanyId = typeof reqBody.company_id === 'string'
      ? reqBody.company_id
      : null

    // 24h guardrail: on first opt-in, the queue may contain arbitrarily
    // old undelivered rows. Only send drops from the last 24 h.
    const cutoff = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()

    let query = adminClient
      .from('low_stock_notifications')
      .select('id, company_id, product_name, current_quantity, min_quantity')
      .is('sent_at', null)
      .gte('created_at', cutoff)
      .order('created_at')
      .limit(100)

    if (filterCompanyId) query = query.eq('company_id', filterCompanyId)

    const { data: notifications, error: fetchError } = await query
```

Everything below this block (group-by-company, send, mark sent) is unchanged.

- [ ] **Step 5.3: Restart the functions container so the edit is picked up**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker
docker compose restart functions
```

Wait ~5 s for the runtime to come back up.

- [ ] **Step 5.4: Smoke-test the function without a body (legacy call shape)**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker
set -a; source ./.env; set +a
curl -sS -X POST "http://localhost:${KONG_HTTP_PORT}/functions/v1/check-low-stock" \
  -H "Authorization: Bearer ${SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json"
```

Expected JSON: `{"ok":true,"sent":0,"notifications":0}` (assuming no rows in the last 24 h matching). If you see `{"error": ...}` with a CORS or auth message, the function is broken — read the docker logs (`docker compose logs functions --tail=50`).

- [ ] **Step 5.5: Smoke-test the function with a non-existent company_id**

```bash
curl -sS -X POST "http://localhost:${KONG_HTTP_PORT}/functions/v1/check-low-stock" \
  -H "Authorization: Bearer ${SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"company_id":"00000000-0000-0000-0000-000000000000"}'
```

Expected JSON: `{"ok":true,"sent":0,"notifications":0}`. No error.

- [ ] **Step 5.6: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add Docker/supabase/functions/check-low-stock/index.ts
git commit -m "$(cat <<'EOF'
feat(check-low-stock): optional company_id filter + 24h guardrail

Adds an optional body.company_id so the new pg_cron dispatcher can
target a single company per call. Backward-compatible — calls without
a body still drain everything (current frontend behavior).

Adds a 24h created_at filter so a company opting in for the first
time does not get a single push containing months of stale low-stock
events.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 4: End-to-end verification of the backend

### Task 6: Exercise the full dispatcher → edge function → web-push path

This task creates no code. It walks through a working push end-to-end against the docker-compose stack and confirms each layer reacts. Skip if you've already validated by hand, but recommended before moving to the frontend chunk.

- [ ] **Step 6.1: Pick a real company and set its notification hour to "now"**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker
# Get the current Berlin hour
BERLIN_HOUR=$(docker compose exec -T db psql -U postgres -d postgres -tAc \
  "SELECT EXTRACT(HOUR FROM (now() AT TIME ZONE 'Europe/Berlin'))::int;" | tr -d ' \r')
echo "Berlin hour right now: ${BERLIN_HOUR}"

# Pick the first company and set its hour
docker compose exec -T db psql -U postgres -d postgres <<SQL
UPDATE public.companies
SET low_stock_notification_hour = ${BERLIN_HOUR}
WHERE id = (SELECT id FROM public.companies ORDER BY created_at LIMIT 1);
SQL
```

Expected: `UPDATE 1`.

- [ ] **Step 6.2: Insert a synthetic low-stock notification (if the queue is empty)**

```bash
# NOTE: products.company (not company_id) is correct — that's the actual
# column name in the products schema, do not "fix" it.
docker compose exec -T db psql -U postgres -d postgres <<SQL
INSERT INTO public.low_stock_notifications
  (company_id, warehouse_id, product_id, product_name, current_quantity, min_quantity)
SELECT
  c.id,
  (SELECT w.id FROM public.warehouses w WHERE w.company_id = c.id LIMIT 1),
  (SELECT p.id FROM public.products p WHERE p.company = c.id LIMIT 1),
  'TEST low-stock push',
  3,
  10
FROM public.companies c
WHERE c.low_stock_notification_hour IS NOT NULL
ORDER BY c.created_at
LIMIT 1;
SQL
```

Expected: `INSERT 0 1`. If the company has no warehouses or no products, that's fine — you can also just confirm the function call works against an empty queue.

- [ ] **Step 6.3: Manually invoke the dispatcher**

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT public.dispatch_low_stock_pushes();"
```

Expected: no WARNING. Returns silently.

- [ ] **Step 6.4: Verify pg_net queued the request**

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT id, method, url, body FROM net.http_request_queue ORDER BY id DESC LIMIT 5;"
```

Expected: at least one row with `method = 'POST'`, `url = 'http://kong:8000/functions/v1/check-low-stock'`, `body` containing the company UUID JSON. If no rows appear, either no company matched the WHERE clause (re-check Step 6.1) or `app.settings.*` is not configured (Task 3 didn't apply).

- [ ] **Step 6.5: Verify the response landed**

Wait ~3 s, then:

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT id, status_code, error_msg FROM net._http_response ORDER BY id DESC LIMIT 5;"
```

Expected: row with `status_code = 200`, `error_msg IS NULL`. If `status_code` is not 200, the edge function is unhappy — read its logs (`docker compose logs functions --tail=100`).

- [ ] **Step 6.6: Verify the queue row was marked sent**

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT id, sent_at FROM public.low_stock_notifications WHERE product_name = 'TEST low-stock push';"
```

Expected: one row, `sent_at IS NOT NULL`.

- [ ] **Step 6.7: Reset the test state**

```bash
docker compose exec -T db psql -U postgres -d postgres <<SQL
DELETE FROM public.low_stock_notifications WHERE product_name = 'TEST low-stock push';
UPDATE public.companies SET low_stock_notification_hour = NULL
WHERE low_stock_notification_hour IS NOT NULL;
SQL
```

Expected: `DELETE 1` and `UPDATE n` (one per company you'd modified — usually 1).

This task has no commit — it's a verification gate only.

---

## Chunk 5: Frontend

### Task 7: Curated IANA timezone list

**Files:**
- Create: `management-frontend/app/lib/timezones.ts`

- [ ] **Step 7.1: Write the file**

Create `management-frontend/app/lib/timezones.ts`:

```ts
/**
 * Curated list of IANA timezone identifiers for the Settings UI.
 *
 * The `companies.timezone` column accepts any IANA name — this list
 * is purely cosmetic to keep the dropdown short. If the user's
 * browser-detected zone isn't in this list, callers should prepend
 * it dynamically (see SettingsLowStockCard).
 */
export type CuratedTimezone = {
  /** IANA name (e.g. "Europe/Berlin"). Stored as-is in the DB. */
  id: string
  /** Human-readable label for the dropdown. */
  label: string
}

export const CURATED_TIMEZONES: CuratedTimezone[] = [
  // Europe
  { id: 'Europe/Berlin',     label: 'Berlin (CET/CEST)' },
  { id: 'Europe/Vienna',     label: 'Vienna (CET/CEST)' },
  { id: 'Europe/Zurich',     label: 'Zurich (CET/CEST)' },
  { id: 'Europe/Amsterdam',  label: 'Amsterdam (CET/CEST)' },
  { id: 'Europe/Paris',      label: 'Paris (CET/CEST)' },
  { id: 'Europe/London',     label: 'London (GMT/BST)' },
  { id: 'Europe/Madrid',     label: 'Madrid (CET/CEST)' },
  { id: 'Europe/Rome',       label: 'Rome (CET/CEST)' },
  { id: 'Europe/Warsaw',     label: 'Warsaw (CET/CEST)' },
  { id: 'Europe/Stockholm',  label: 'Stockholm (CET/CEST)' },
  { id: 'Europe/Helsinki',   label: 'Helsinki (EET/EEST)' },
  { id: 'Europe/Athens',     label: 'Athens (EET/EEST)' },
  { id: 'Europe/Istanbul',   label: 'Istanbul (TRT)' },

  // Americas
  { id: 'America/New_York',  label: 'New York (EST/EDT)' },
  { id: 'America/Chicago',   label: 'Chicago (CST/CDT)' },
  { id: 'America/Denver',    label: 'Denver (MST/MDT)' },
  { id: 'America/Los_Angeles', label: 'Los Angeles (PST/PDT)' },
  { id: 'America/Toronto',   label: 'Toronto (EST/EDT)' },
  { id: 'America/Mexico_City', label: 'Mexico City (CST/CDT)' },
  { id: 'America/Sao_Paulo', label: 'São Paulo (BRT)' },

  // Asia / Pacific
  { id: 'Asia/Dubai',        label: 'Dubai (GST)' },
  { id: 'Asia/Singapore',    label: 'Singapore (SGT)' },
  { id: 'Asia/Tokyo',        label: 'Tokyo (JST)' },
  { id: 'Asia/Shanghai',     label: 'Shanghai (CST)' },
  { id: 'Asia/Hong_Kong',    label: 'Hong Kong (HKT)' },
  { id: 'Asia/Seoul',        label: 'Seoul (KST)' },
  { id: 'Australia/Sydney',  label: 'Sydney (AEST/AEDT)' },
  { id: 'Pacific/Auckland',  label: 'Auckland (NZST/NZDT)' },

  // UTC anchor
  { id: 'UTC',               label: 'UTC' },
]

/** Browser-detected zone, falling back to Europe/Berlin if Intl is unavailable. */
export function detectBrowserTimezone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'Europe/Berlin'
  } catch {
    return 'Europe/Berlin'
  }
}
```

- [ ] **Step 7.2: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add management-frontend/app/lib/timezones.ts
git commit -m "$(cat <<'EOF'
feat(settings): add curated IANA timezone list

Used by the upcoming SettingsLowStockCard. Curated subset of ~30 zones
spanning EU, Americas, Asia/Pacific plus UTC anchor. Falls back to
Europe/Berlin if Intl is unavailable.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 8: i18n keys for the low-stock settings card

**Files:**
- Modify: `management-frontend/i18n/locales/en.json`
- Modify: `management-frontend/i18n/locales/de.json`

- [ ] **Step 8.1: Confirm the locale files exist where expected**

```bash
ls -la /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/i18n/locales/en.json \
       /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/i18n/locales/de.json
```

Expected: both files listed. If either is missing, run `grep -rln "aiInsights" /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend --include="*.json"` to find where the existing `settings.aiInsights` key lives and adjust the paths below. Then update the `git add` in Step 8.5 to match.

- [ ] **Step 8.2: Add keys to `en.json`**

Inside the existing `settings` object, add a new `lowStock` block. Adapt the indentation to match the file:

```json
    "lowStock": {
      "title": "Low-Stock Daily Push",
      "description": "Get a daily summary of products that newly dropped below their minimum stock since the last push. Disabled means no automatic push — entries still appear on the Warehouse page.",
      "timezone": "Timezone",
      "sendTime": "Send time",
      "disabledOption": "Disabled",
      "save": "Save schedule",
      "saved": "Schedule updated",
      "saving": "Saving…",
      "loadError": "Could not load schedule",
      "saveError": "Could not save schedule"
    }
```

Place the block alphabetically among other `settings.*` blocks if the file is ordered, otherwise next to `settings.aiInsights`.

- [ ] **Step 8.3: Add the same keys to `de.json`**

```json
    "lowStock": {
      "title": "Tagespush für niedrigen Bestand",
      "description": "Täglich eine Zusammenfassung der Produkte, die seit dem letzten Push unter ihren Mindestbestand gefallen sind. „Aus" bedeutet kein automatischer Push — Einträge erscheinen weiterhin auf der Lager-Seite.",
      "timezone": "Zeitzone",
      "sendTime": "Sendezeit",
      "disabledOption": "Aus",
      "save": "Zeitplan speichern",
      "saved": "Zeitplan aktualisiert",
      "saving": "Speichere…",
      "loadError": "Zeitplan konnte nicht geladen werden",
      "saveError": "Zeitplan konnte nicht gespeichert werden"
    }
```

- [ ] **Step 8.4: Validate JSON syntax**

```bash
node -e "JSON.parse(require('fs').readFileSync('<path-to-en.json>','utf-8'))"
node -e "JSON.parse(require('fs').readFileSync('<path-to-de.json>','utf-8'))"
```

Substitute the actual paths from Step 8.1. Both must complete silently.

- [ ] **Step 8.5: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "$(cat <<'EOF'
i18n(settings): add lowStock card translations

EN + DE keys for the new low-stock daily push settings card.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 9: Build the `SettingsLowStockCard.vue` component

**Files:**
- Create: `management-frontend/app/components/settings/LowStockCard.vue`

The card mirrors `AiKeyCard.vue`'s shape: own data fetch, own loading/error/success state, own save handler. No new composable — Supabase calls inline.

- [ ] **Step 9.1: Write the component**

Create `management-frontend/app/components/settings/LowStockCard.vue`:

```vue
<script setup lang="ts">
import { IconBellRinging, IconLoader2 } from '@tabler/icons-vue'
import { CURATED_TIMEZONES, detectBrowserTimezone } from '~/lib/timezones'

const { t } = useI18n()
const supabase = useSupabaseClient()
const { organization, role } = useOrganization()

const timezone = ref<string>(detectBrowserTimezone())
const hour = ref<number | null>(null) // null = disabled
const loading = ref(false)
const error = ref('')
const success = ref('')

/** Merged dropdown list: curated zones + browser-detected zone if missing. */
const timezoneOptions = computed(() => {
  const browserTz = detectBrowserTimezone()
  const known = new Set(CURATED_TIMEZONES.map(z => z.id))
  if (!known.has(browserTz)) {
    return [{ id: browserTz, label: `${browserTz} (detected)` }, ...CURATED_TIMEZONES]
  }
  return CURATED_TIMEZONES
})

const hourOptions = computed(() => {
  return Array.from({ length: 24 }, (_, i) => ({
    value: i,
    label: `${i.toString().padStart(2, '0')}:00`,
  }))
})

async function load() {
  if (!organization.value?.id) return
  loading.value = true
  error.value = ''
  try {
    const { data, error: fetchErr } = await supabase
      .from('companies')
      .select('timezone, low_stock_notification_hour')
      .eq('id', organization.value.id)
      .single()
    if (fetchErr) throw fetchErr
    const row = data as any
    if (row?.timezone) timezone.value = row.timezone
    hour.value = typeof row?.low_stock_notification_hour === 'number'
      ? row.low_stock_notification_hour
      : null
  } catch (err: unknown) {
    error.value = err instanceof Error ? err.message : t('settings.lowStock.loadError')
  } finally {
    loading.value = false
  }
}

async function save() {
  if (!organization.value?.id) return
  loading.value = true
  error.value = ''
  success.value = ''
  try {
    const { error: updateErr } = await supabase
      .from('companies')
      .update({
        timezone: timezone.value,
        low_stock_notification_hour: hour.value,
      })
      .eq('id', organization.value.id)
    if (updateErr) throw updateErr
    success.value = t('settings.lowStock.saved')
  } catch (err: unknown) {
    error.value = err instanceof Error ? err.message : t('settings.lowStock.saveError')
  } finally {
    loading.value = false
  }
}

watch(() => organization.value?.id, (id) => {
  if (import.meta.client && id && role.value === 'admin') load()
}, { immediate: true })
</script>

<template>
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <div class="mb-5 flex items-center gap-2">
      <IconBellRinging class="size-5 text-primary" />
      <div>
        <h2 class="text-lg font-semibold">{{ t('settings.lowStock.title') }}</h2>
        <p class="text-sm text-muted-foreground">{{ t('settings.lowStock.description') }}</p>
      </div>
    </div>

    <form class="space-y-4" @submit.prevent="save">
      <div class="space-y-1">
        <label for="ls-timezone" class="text-sm font-medium">{{ t('settings.lowStock.timezone') }}</label>
        <select
          id="ls-timezone"
          v-model="timezone"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option v-for="tz in timezoneOptions" :key="tz.id" :value="tz.id">{{ tz.label }}</option>
        </select>
      </div>

      <div class="space-y-1">
        <label for="ls-hour" class="text-sm font-medium">{{ t('settings.lowStock.sendTime') }}</label>
        <select
          id="ls-hour"
          v-model="hour"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        >
          <option :value="null">{{ t('settings.lowStock.disabledOption') }}</option>
          <option v-for="opt in hourOptions" :key="opt.value" :value="opt.value">{{ opt.label }}</option>
        </select>
      </div>

      <p v-if="error" class="text-sm text-destructive">{{ error }}</p>
      <p v-if="success" class="text-sm text-green-600">{{ success }}</p>

      <button
        type="submit"
        :disabled="loading"
        class="inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
      >
        <IconLoader2 v-if="loading" class="mr-2 size-4 animate-spin" />
        <span v-if="loading">{{ t('settings.lowStock.saving') }}</span>
        <span v-else>{{ t('settings.lowStock.save') }}</span>
      </button>
    </form>
  </div>
</template>
```

Note: the `~/lib/timezones` import relies on Nuxt's auto-aliased `~/` pointing to `app/`. If that fails at build time, switch to a relative path `../../lib/timezones`.

- [ ] **Step 9.2: Type-check / build the frontend**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npm run build 2>&1 | tail -20
```

Expected: build succeeds. If you see TypeScript errors about `tabler-icons-vue` imports, copy the exact import style from `AiKeyCard.vue` (it works there). If `useSupabaseClient` complains about types, the existing `AiKeyCard.vue` shows the established pattern — match it.

If `npm run build` is too slow, `npm run dev` and visually open `/settings` once the new card is wired (Task 10).

- [ ] **Step 9.3: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add management-frontend/app/components/settings/LowStockCard.vue
git commit -m "$(cat <<'EOF'
feat(settings): add LowStockCard component

Timezone select + hour select (with Disabled option). Loads and saves
companies.timezone + companies.low_stock_notification_hour. Admin-only
via existing role gate in settings/index.vue.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 10: Wire the card into the Settings page and remove the warehouse drain

**Files:**
- Modify: `management-frontend/app/pages/settings/index.vue`
- Modify: `management-frontend/app/pages/warehouse/index.vue`

- [ ] **Step 10.1: Add `<SettingsLowStockCard />` to settings page**

In `management-frontend/app/pages/settings/index.vue` line ~19, between `<SettingsAiKeyCard />` and `<SettingsStripeCard />`, insert:

```vue
      <SettingsLowStockCard />
```

The component is auto-imported by Nuxt from `app/components/settings/LowStockCard.vue` as `<SettingsLowStockCard>`. Confirm by grepping for how the other card names are resolved:

```bash
grep -n "SettingsAiKeyCard" /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend/app/pages/settings/index.vue
```

If the existing cards resolve under a different name pattern, match it.

- [ ] **Step 10.2: Remove the `/warehouse` page-load drain**

In `management-frontend/app/pages/warehouse/index.vue`:

Line ~38 — remove `checkLowStockNotifications` from the destructured import. Before:

```ts
  fetchMinStocks, setMinStock, fetchVelocityDays, setVelocityDays, velocityDays, checkLowStockNotifications,
```

After (drop `checkLowStockNotifications,`):

```ts
  fetchMinStocks, setMinStock, fetchVelocityDays, setVelocityDays, velocityDays,
```

Line ~105-106 — remove the comment + call:

```ts
  // Trigger processing of any queued low-stock notifications (best-effort)
  checkLowStockNotifications()
```

Both lines deleted entirely.

- [ ] **Step 10.3: Verify the composable export is harmless**

The `checkLowStockNotifications` function in `useWarehouse.ts` stays — it's a harmless export with no callers now. That's intentional per the spec; do NOT delete it (leaves a re-attachment point for a future "Send now" button).

```bash
grep -rn "checkLowStockNotifications" /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
```

Expected: only matches inside `useWarehouse.ts` (export site). Zero matches anywhere else.

- [ ] **Step 10.4: Smoke-test in the dev server**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/management-frontend
npm run dev
```

In another shell or browser:
1. Open `http://localhost:3000/settings`. Log in as an admin user (use credentials from `user_dev_credentials.md` memory if needed).
2. The new "Low-Stock Daily Push" card appears between "AI Insights" and "Stripe".
3. Timezone shows the browser-detected zone or `Europe/Berlin`. Hour shows "Disabled".
4. Pick `Europe/Berlin` + `08:00`, click Save. Expect green "Schedule updated" toast.
5. Reload the page — the values stick.
6. Switch to `Disabled`, save — green toast, values stick.
7. Open `/warehouse` → DevTools Network → confirm there is **no** POST to `/functions/v1/check-low-stock`.

If any of (1–6) fails, fix and re-run. (7) is the contract change — must be empty.

- [ ] **Step 10.5: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add management-frontend/app/pages/settings/index.vue \
        management-frontend/app/pages/warehouse/index.vue
git commit -m "$(cat <<'EOF'
feat(settings,warehouse): wire LowStockCard + drop /warehouse drain

The new cron-based dispatcher now drains the queue; calling on
/warehouse page load would double-send within the same hour for the
admin that just visited.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Chunk 6: Final end-to-end check

### Task 11: Full deploy-order sanity check

This task is a final readthrough plus one e2e check. No code changes.

- [ ] **Step 11.1: Re-run the dispatcher with everything in place**

Pick the same company you used in Task 6, set its hour to "now", run the dispatcher, observe the push.

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/Docker
BERLIN_HOUR=$(docker compose exec -T db psql -U postgres -d postgres -tAc \
  "SELECT EXTRACT(HOUR FROM (now() AT TIME ZONE 'Europe/Berlin'))::int;" | tr -d ' \r')

docker compose exec -T db psql -U postgres -d postgres <<SQL
UPDATE public.companies
SET low_stock_notification_hour = ${BERLIN_HOUR}
WHERE id = (SELECT id FROM public.companies ORDER BY created_at LIMIT 1);

-- synthetic queue entry
INSERT INTO public.low_stock_notifications
  (company_id, warehouse_id, product_id, product_name, current_quantity, min_quantity)
SELECT
  c.id,
  (SELECT w.id FROM public.warehouses w WHERE w.company_id = c.id LIMIT 1),
  (SELECT p.id FROM public.products p WHERE p.company = c.id LIMIT 1),
  'FINAL e2e test',
  2,
  10
FROM public.companies c
WHERE c.low_stock_notification_hour IS NOT NULL
LIMIT 1;
SQL

# Fire the dispatcher
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT public.dispatch_low_stock_pushes();"

# Confirm http call landed and queue row was stamped
sleep 3
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT status_code FROM net._http_response ORDER BY id DESC LIMIT 1;"
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT product_name, sent_at FROM public.low_stock_notifications WHERE product_name = 'FINAL e2e test';"
```

Expected:
- `status_code = 200`
- `sent_at IS NOT NULL`

- [ ] **Step 11.2: Clean up**

```bash
docker compose exec -T db psql -U postgres -d postgres <<SQL
DELETE FROM public.low_stock_notifications WHERE product_name = 'FINAL e2e test';
UPDATE public.companies SET low_stock_notification_hour = NULL
WHERE low_stock_notification_hour IS NOT NULL;
SQL
```

- [ ] **Step 11.3: Confirm cron is still scheduled and will fire next hour naturally**

```bash
docker compose exec -T db psql -U postgres -d postgres -c \
  "SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'low_stock_daily_push';"
```

Expected: one row, `active = true`, `schedule = '0 * * * *'`. At the next top-of-hour the dispatcher will run automatically. (No company has a notification hour set after Step 11.2's cleanup, so it will be a fast no-op.)

- [ ] **Step 11.4: Final commit (none expected)**

Verify nothing new was staged accidentally:

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git status
```

Expected: working tree clean (modulo the pre-existing `ios/` changes from Pre-flight Step 0.1).

- [ ] **Step 11.5: Push when ready**

```bash
git log --oneline -10
```

Expected commits in order: chunk-1 (preload), chunk-1 (migration), chunk-2 (update.sh), chunk-2 (setup.sh), chunk-3 (edge function), chunk-5 (timezones), chunk-5 (i18n), chunk-5 (LowStockCard), chunk-5 (wire + drop drain). Eight or nine commits total.

```bash
# Pushing is the user's call — do NOT push without explicit user confirmation.
git push origin main  # ← only run if the user says go
```

---

## Out of scope (reminder)

- Multiple slots per day, sub-hour granularity, quiet hours.
- Catch-up sweep for missed cron ticks (if pg_cron pauses, drops are lost for that company until next day).
- "Send now" button on the Settings card.
- Snapshot-based send (currently below-min view).
- Fix for the orphan case where raising `product_min_stock` above the current stock does not fire the trigger.
- iOS / Android native push.

## Deploy ordering for production

When this plan lands on `main` and operators pull:

1. They `git pull` and see `docker-compose.yml` + a new migration + script changes.
2. They run `./update.sh`. The script will:
   - Build/pull updated frontend image
   - Recreate the `db` container (picks up the new `shared_preload_libraries`)
   - Apply the migration (creates extensions, function, cron entry)
   - Set `app.settings.supabase_url` + `service_role_key`
   - Restart `functions` to pick up the new edge function code
3. They open the Settings page in the deployed frontend and pick a time.

Step 2's order is enforced by `update.sh` itself — the `ALTER DATABASE` block is positioned in this plan to run AFTER the DB-restart-implicit-in-`compose-up` is healthy, BEFORE migrations.

## Backout

If anything is on fire:

```sql
-- Disable the cron job without losing the configuration
UPDATE cron.job SET active = false WHERE jobname = 'low_stock_daily_push';
```

To fully revert (do not do this on prod without coordinating):

```sql
SELECT cron.unschedule('low_stock_daily_push');
DROP FUNCTION public.dispatch_low_stock_pushes();
ALTER TABLE public.companies DROP COLUMN low_stock_notification_hour;
-- Leave companies.timezone in place — it may be used elsewhere later.
```

Frontend rollback: revert the deploy. The `companies` columns + extensions can stay until the next coordinated cleanup.

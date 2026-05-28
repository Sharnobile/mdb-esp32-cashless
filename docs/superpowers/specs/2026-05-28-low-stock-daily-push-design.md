# Low-Stock Daily Push via Cron

**Date**: 2026-05-28
**Status**: Design — pending user review
**Scope**: Self-hosted Supabase (`Docker/supabase/`), `check-low-stock` edge function, management frontend Settings page

## Problem

Low-stock push notifications are queued by a database trigger
(`on_stock_change_check_low_stock`) on every UPDATE/DELETE of
`warehouse_stock_batches`. Entries land in `low_stock_notifications`
with `sent_at = NULL`. A queue-drainer edge function
(`check-low-stock`) reads unsent rows, dispatches web-push via
`sendPushToUsers`, then stamps `sent_at`.

The drainer is invoked from exactly one place:
`loadWarehouseData()` in [warehouse/index.vue:106](management-frontend/app/pages/warehouse/index.vue:106).
That means push notifications only get sent when an admin opens the
`/warehouse` page — defeating the purpose of push (reaching the user
*when they are not in the app*). In practice users only see a push
once they have already navigated to the surface that shows the same
information visually.

## Goals

- Drain the `low_stock_notifications` queue on a schedule, not on a
  page visit.
- Make the schedule **configurable per company** through the Settings UI.
- Use the company's **local timezone** for the configured time, so
  "08:00" means 08:00 in their actual day, including DST.
- Default to **off** for existing companies — opt-in, no surprise pushes.
- Keep the existing trigger and queue table unchanged, so older clients
  (PWA + native iOS) keep working without coordination.

## Non-goals

- Multiple slots per day (e.g. 08:00 + 16:00).
- Sub-hour granularity (15-min slots).
- Quiet hours, weekend skip, holiday calendar.
- Switching to a state-based "snapshot of everything currently below
  min" model. User explicitly chose the delta-based queue drain.
- Manual "send now" button on the frontend. The composable helper stays
  in place for a possible future trigger but no UI hook in v1.
- Fixing the orphan case where raising `product_min_stock` above the
  current stock does not fire the trigger. Tracked as a separate
  follow-up.
- Same feature in native iOS or Android. Both already read company
  settings via the standard Supabase client; they will not need
  changes to *receive* the push (web-push registration already exists
  on the PWA — native push is a separate stack and out of scope).

## Architecture

```
warehouse_stock_batches  UPDATE / DELETE
        │
        ▼
DB trigger  on_stock_change_check_low_stock      (unchanged)
        │
        ▼
low_stock_notifications  sent_at IS NULL         (unchanged queue table)
        ▲
        │  drain
        │
pg_cron  dispatch_low_stock_pushes               (NEW — every full hour)
        │
        │  for each company where
        │    low_stock_notification_hour =
        │    EXTRACT(HOUR FROM now() AT TIME ZONE companies.timezone)
        │
        ▼
net.http_post  →  /functions/v1/check-low-stock  (extended: optional company_id filter)
        │
        ▼
sendPushToUsers(...)  → web-push to all members of the company
```

Removed: the `checkLowStockNotifications()` call from
`loadWarehouseData()` in [warehouse/index.vue:106](management-frontend/app/pages/warehouse/index.vue:106).
The composable helper remains in `useWarehouse.ts` (no current caller —
left in place because it is harmless and may be reused for a future
"send now" button).

## Database changes

A new migration `YYYYMMDDHHMMSS_low_stock_daily_push.sql` adds:

### 1. Two columns on `companies`

```sql
ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS timezone text NOT NULL DEFAULT 'Europe/Berlin',
  ADD COLUMN IF NOT EXISTS low_stock_notification_hour smallint
    CHECK (low_stock_notification_hour IS NULL
           OR (low_stock_notification_hour BETWEEN 0 AND 23));
```

Semantics:
- `timezone` — IANA name. `Europe/Berlin` chosen as default because the
  entire current customer base is in DACH; the column is a `text` so
  any IANA zone works.
- `low_stock_notification_hour` — `NULL` means push is disabled; `0..23`
  means "send at this hour of local time".

Both columns have safe defaults — existing reads of `companies` are
unaffected.

### 2. Extensions

```sql
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;
```

`supabase/postgres:15.8.1.060` (the image pinned in
`Docker/docker-compose.yml`) ships with both extensions available.
`CREATE EXTENSION IF NOT EXISTS` is idempotent and safe on existing
installs that already have them.

### 3. Dispatcher function

```sql
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
  IF v_url IS NULL OR v_key IS NULL THEN
    RAISE WARNING 'dispatch_low_stock_pushes: app.settings.supabase_url or service_role_key not set; skipping';
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
```

Notes:
- `SECURITY DEFINER` plus `SET search_path = public, extensions`
  follows the project convention (`pgcrypto` lives in `extensions`; we
  read the same project rule that caused the 2026-05-22 `cash_book`
  fix).
- The guard against missing `app.settings.*` makes the function safe
  to ship before `setup.sh` / `update.sh` write the settings. Old
  installs without these settings simply log a warning and no-op
  rather than failing.
- `EXTRACT(HOUR FROM now() AT TIME ZONE timezone)` handles DST
  transparently — at the moment the clock springs forward, that hour
  is skipped naturally, and on fall-back it fires twice (acceptable
  for a delta-drainer because the second drain finds an empty queue).
- The function calls `net.http_post` once per due company. `pg_net`
  queues the HTTP calls asynchronously; the function returns
  immediately without waiting for HTTP responses.

### 4. pg_cron schedule

```sql
SELECT cron.schedule(
  'low_stock_daily_push',
  '0 * * * *',
  $$SELECT public.dispatch_low_stock_pushes();$$
);
```

One global cron entry, fires at the top of every hour, in UTC (pg_cron
default). The per-company timezone offset is applied inside
`dispatch_low_stock_pushes`, not by the schedule expression.

The migration must guard against duplicate cron entries on re-apply.
`cron.schedule()` is upsert-style by job name in recent pg_cron
versions, but the migration wraps the call to be explicit:

```sql
DO $$
BEGIN
  PERFORM cron.unschedule('low_stock_daily_push')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'low_stock_daily_push');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

SELECT cron.schedule(
  'low_stock_daily_push',
  '0 * * * *',
  $$SELECT public.dispatch_low_stock_pushes();$$
);
```

The migration is otherwise immutable — fixes to the dispatcher
function in the future use `CREATE OR REPLACE FUNCTION` in a later
migration, per the project's migration-immutability rule
(`feedback_migration_immutability.md`).

## Setup / update scripts

Two new Postgres settings must be set per installation so the
dispatcher knows where to call:

```sql
ALTER DATABASE postgres SET app.settings.supabase_url     = 'http://kong:8000';
ALTER DATABASE postgres SET app.settings.service_role_key = '<SERVICE_ROLE_KEY>';
```

These go into:
- `Docker/setup.sh` — append the two `ALTER DATABASE` calls after the
  service-role key is generated, before any migration runs.
- `Docker/update.sh` — same `ALTER DATABASE` calls, idempotent (they
  overwrite the existing setting on every update so a regenerated key
  is picked up).

The internal URL `http://kong:8000` is the docker-compose service
hostname for the API gateway — the same URL used by the existing
forwarder service for HTTP calls into the API. Edge functions sit
behind the gateway under `/functions/v1/`.

`ALTER DATABASE` settings persist across restarts but live only at the
database level — they do not appear in `Docker/.env` and are not
exposed to the rest of the stack. This is intentional: the
service-role key is already in the gateway and the dispatcher should
not need a separate route in or out.

## Edge function change

`Docker/supabase/functions/check-low-stock/index.ts` — single additive
change to accept an optional `company_id` filter:

```ts
const contentLength = req.headers.get('content-length')
const body = contentLength && contentLength !== '0'
  ? await req.json().catch(() => ({}))
  : {}
const filterCompanyId = typeof body.company_id === 'string'
  ? body.company_id
  : null

let q = adminClient
  .from('low_stock_notifications')
  .select('id, company_id, product_name, current_quantity, min_quantity')
  .is('sent_at', null)
  .order('created_at')
  .limit(100)

if (filterCompanyId) q = q.eq('company_id', filterCompanyId)

const { data: notifications, error: fetchError } = await q
```

Everything below this point (group-by-company, send, mark sent) is
unchanged. The function still works when called without a body — same
behavior as today, drains the entire queue. Old callers that have not
been updated remain functional, including the frontend during the
brief window before the page-load call is removed.

## Frontend changes

### Remove the page-load drain

[warehouse/index.vue](management-frontend/app/pages/warehouse/index.vue):
delete the call to `checkLowStockNotifications()` from
`loadWarehouseData()`. The destructured import of the helper from
`useWarehouse()` can also be removed since no other call site uses it
on this page.

The composable export itself in
[useWarehouse.ts:960](management-frontend/app/composables/useWarehouse.ts:960)
stays — harmless, and a future "Send test push now" button could reuse
it.

### New SettingsLowStockCard

Mirror the existing `SettingsAiKeyCard.vue` shape, placed in
[settings/index.vue](management-frontend/app/pages/settings/index.vue)
between `SettingsAiKeyCard` and `SettingsStripeCard`.

Fields:

| Field | Control | Persists to |
|---|---|---|
| Timezone | `<Select>` of common IANA zones, sensible default = `Intl.DateTimeFormat().resolvedOptions().timeZone`. Falls back to `Europe/Berlin` if the browser-detected value is not in the curated list. | `companies.timezone` |
| Send time | `<Select>` with 24 hourly options (`00:00`, `01:00`, …, `23:00`) plus a leading **"Disabled"** option (which writes `NULL`). | `companies.low_stock_notification_hour` |

A short hint text under the controls:
> "Send a daily push at this time with products that newly dropped
> below their minimum stock since the last push. Disabled means no
> automatic push — entries still appear on the Warehouse page."

Save handler updates both columns in one `companies` row update,
gated by `isAdmin`. Existing card pattern (loading state, success
toast, error toast) is reused.

i18n: new keys under `settings.lowStock.*` in both `en` and `de`.

### IANA zone list

A small curated list of zones in the frontend
(`management-frontend/app/lib/timezones.ts`) — 30-50 entries covering
common DACH/EU/US/APAC zones. The list is cosmetic; the column
accepts any IANA name. If the browser-detected zone is not in the
list we add it dynamically as the top entry to avoid forcing the user
to pick something else.

### Composable

A tiny `useLowStockSchedule()` composable in
`management-frontend/app/composables/` if it makes the card cleaner,
otherwise the read/write can be inlined in the card component. Final
shape decided during implementation; not a design-level concern.

## Removed paths

| Path | Why |
|---|---|
| `loadWarehouseData()` → `checkLowStockNotifications()` call | The cron now drains the queue; calling on page load would cause double-sends within the same hour window for the company that just visited the page. |

## Backward compatibility

| Surface | Status |
|---|---|
| `low_stock_notifications` table | Unchanged. Schema, RLS, trigger function and trigger itself are all preserved. |
| `check-low-stock` edge function | New `company_id` body field is **optional**. Calls without a body keep the existing "drain all" behavior. |
| `companies` table | Two new columns, both with safe defaults. No existing SELECT depends on these columns. |
| iOS / Android native clients | Neither client reads `companies.timezone` or `companies.low_stock_notification_hour`. Web-push registration is PWA-only — native clients are not affected. |
| Old frontend talking to new backend | Still calls `check-low-stock` on `/warehouse` visit. Function works without `company_id`. Worst case: company A admin visits `/warehouse` at 08:30 and the cron also fires at 09:00 — two pushes that hour. Acceptable transient until frontend is deployed. |
| New frontend talking to old backend | Settings update writes columns that do not exist. Supabase returns `column "..." does not exist`. Frontend deploy MUST follow the DB migration. Standard ordering. |
| Migration immutability | The migration uses `IF NOT EXISTS`, `CREATE OR REPLACE`, and the `DO $$ ... $$` guard around `cron.unschedule`. Re-running it is a no-op. Future fixes to the dispatcher function go in a later migration. |

## Configuration files

The "new env var" checklist from CLAUDE.md does NOT apply here — the
dispatcher does not read environment variables. It reads Postgres
session settings written by `ALTER DATABASE`. The only files that
change beyond migrations and code are:

| File | Change |
|---|---|
| `Docker/setup.sh` | Append two `ALTER DATABASE` calls for `app.settings.supabase_url` and `app.settings.service_role_key`. |
| `Docker/update.sh` | Same, idempotent so the calls run on every update. |

Both `config.toml` (`[edge_runtime.secrets]`) and `Docker/.env` are
unchanged.

## Edge cases

| Case | Behavior |
|---|---|
| Company has `low_stock_notification_hour = NULL` | Dispatcher skips them. No HTTP call, no push. |
| Company's `timezone` is invalid IANA name | `now() AT TIME ZONE 'foo'` raises an exception inside the loop. The `FOR ... LOOP` aborts; later companies are skipped. Mitigation: a `CHECK` constraint is overkill (IANA names change), but the Settings UI restricts input to the curated list + browser-detected name, so invalid values can only enter via direct SQL. Acceptable. |
| `app.settings.supabase_url` / `service_role_key` not set on an old install that hasn't run the updated `update.sh` | Dispatcher logs `WARNING` and returns. No push, no error. User-visible symptom: pushes never arrive. |
| DST spring forward at 02:00 → 03:00 | Hour `02` does not exist in local time on that date. A company with `low_stock_notification_hour = 2` simply does not match any tick that day, no push. Next day resumes. |
| DST fall back at 03:00 → 02:00 | Hour `02` happens twice. Cron ticks at the UTC equivalent of both. Second drain finds the queue empty (already sent), no double push in practice. |
| Service-role key rotated | `update.sh` re-runs the `ALTER DATABASE` and the dispatcher picks up the new key on its next call (Postgres re-evaluates `current_setting` per query). |
| Edge function down or returning 5xx | `net.http_post` queues asynchronously; failures are logged into `net._http_response`. The queue row stays `sent_at = NULL` so the next hour's drain attempts it again (but only for that company because the dispatcher already moved on). For an *individual company* whose cron hour just passed, the queue still won't drain until they visit `/warehouse` or 24 h pass. Acceptable for v1 — observable in `net._http_response` table. |
| Cron runs but no companies are due | `FOR ... LOOP` body never executes. Returns in <1ms. |
| Many companies on the same hour | Loop fires N `net.http_post` calls back-to-back. `pg_net` handles backpressure; no batching needed for foreseeable scale (<1000 companies). |
| Queue has rows for company X but `low_stock_notification_hour = NULL` | They sit in the queue forever. **By design** — the only drain trigger is cron. Once the user opts in to a notification hour, the next tick drains the accumulated rows. If they never opt in, the rows stay. |
| Trigger orphan: someone raises `product_min_stock` above current stock | No row inserted into `low_stock_notifications` because the trigger fires on `warehouse_stock_batches`, not `product_min_stock`. **Existing bug**, not introduced by this change. Out of scope. |

## Testing

### Migration

- `supabase migration up` runs the migration cleanly on a fresh local
  DB.
- Re-running the migration (manually via `\i` in psql) is a no-op.
- After migration: `SELECT * FROM cron.job WHERE jobname =
  'low_stock_daily_push';` returns one row. `pg_cron` and `pg_net` are
  in `pg_extension`.

### Dispatcher

- Set `app.settings.supabase_url` and `app.settings.service_role_key`
  for the test database.
- Insert two companies, one with `low_stock_notification_hour =
  EXTRACT(HOUR FROM now() AT TIME ZONE 'Europe/Berlin')::smallint`
  (i.e. the current hour in Berlin), the other with `NULL`.
- Run `SELECT public.dispatch_low_stock_pushes();` manually.
- Verify in `net._http_response` (or `net.http_request_queue`) that
  exactly one POST was queued, to the right URL, with the right
  company_id in the body.

### Edge function

- POST to `/functions/v1/check-low-stock` with `{"company_id":
  "<uuid>"}` — only that company's rows are drained.
- POST with no body — all rows are drained (existing behavior).
- POST with `{"company_id": "invalid"}` — no rows match, returns
  `{ok: true, sent: 0, notifications: 0}`.

### Frontend

- Settings card shows the current values (or "Disabled" + detected
  timezone for a fresh install).
- Saving "08:00 / Europe/Berlin" updates the columns and shows a
  success toast.
- Saving "Disabled" sets `low_stock_notification_hour` to `NULL`.
- `/warehouse` no longer calls `check-low-stock`. Network tab
  confirms.

### End-to-end (manual)

- Configure a test company for `low_stock_notification_hour = now-hour`.
- Force a stock drop below min for at least one product.
- Verify a push lands at the next top-of-hour tick.

## Risks

1. **`app.settings.*` not propagated**: If `update.sh` lands but the
   user does not re-run it on an existing install, the dispatcher
   silently no-ops. Mitigation: log a `WARNING` so it shows up in
   `docker compose logs db`; document in the release notes that
   existing installs must re-run `update.sh`.
2. **pg_net edge function URL changes** when running locally vs.
   self-hosted prod (`http://127.0.0.1:54321` for `supabase start` vs.
   `http://kong:8000` for docker-compose). `setup.sh` writes the
   correct value for its own environment; local dev needs an
   equivalent setting. Add a `Docker/supabase/.env` line and a note
   in `config.toml`'s comments.
3. **Cron drift**: if pg_cron is paused (e.g. db restart) the
   dispatcher misses its tick. Next tick picks up the queue normally
   for the *next* hour's companies — companies whose hour just passed
   wait 23 hours for the next try. Acceptable for v1 ("Tagespush"
   tolerance is high); a future enhancement could add a "catch-up"
   sweep that processes queue rows older than 24h regardless of hour.
4. **Push spam if a user has many low-stock events**: the existing
   `check-low-stock` already groups notifications per company into a
   single push payload, batching product names. No change needed.
5. **RLS on the new columns**: `companies` already has policies that
   let admins update their own row and viewers read it. The new
   columns inherit those policies automatically — no separate policy
   needed.

## Out of scope

- Multiple slots per day, sub-hour granularity, quiet hours.
- Catch-up sweep for missed cron ticks.
- A "Send now" button on the Settings card.
- Switching to a snapshot-based send model (chosen against by user).
- Trigger orphan fix for `product_min_stock` raises.
- iOS / Android native push (separate stack; web-push is PWA-only).

## Files affected

| File | Change |
|---|---|
| `Docker/supabase/migrations/YYYYMMDDHHMMSS_low_stock_daily_push.sql` | New file. Adds two columns to `companies`, enables `pg_cron` + `pg_net`, creates `dispatch_low_stock_pushes()`, schedules the cron job. |
| `Docker/supabase/functions/check-low-stock/index.ts` | Additive: read optional `company_id` from request body, filter the query. |
| `Docker/setup.sh` | Append `ALTER DATABASE` for `app.settings.supabase_url` and `app.settings.service_role_key`. |
| `Docker/update.sh` | Same `ALTER DATABASE` calls, idempotent. |
| `management-frontend/app/pages/warehouse/index.vue` | Remove the `checkLowStockNotifications()` call in `loadWarehouseData()`. |
| `management-frontend/app/components/SettingsLowStockCard.vue` | New file. Timezone select + send-time select + save button. |
| `management-frontend/app/pages/settings/index.vue` | Add `<SettingsLowStockCard />` to the admin grid. |
| `management-frontend/app/lib/timezones.ts` | New file. Curated IANA list for the select. |
| `management-frontend/app/locales/en.json` | Add `settings.lowStock.*` keys. |
| `management-frontend/app/locales/de.json` | Same, in German. |

No new edge functions, no new tables, no MQTT changes, no firmware
changes.

## Effort estimate

~150 lines of SQL (migration), ~20 lines of TS in the edge function,
~150 lines of Vue across the new card and the timezone list, ~10
lines each in `setup.sh` and `update.sh`. Single implementation
session of moderate length.

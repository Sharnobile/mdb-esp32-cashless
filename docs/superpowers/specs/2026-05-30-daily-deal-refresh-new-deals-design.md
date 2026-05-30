# Daily Deal Refresh + New-Deal Notifications — Design

**Status:** Approved
**Date:** 2026-05-30
**Author:** Claude + Lucien

## Problem

The `/deals` page already fetches retailer offers (via the `deal-source` providers), matches them against the company's products/keywords, caches them, and lets each user pin or archive offers. But:

1. **Refresh is manual** — deals only update when a user clicks refresh or opens the page after the 12 h cache window. Nobody is reliably checking, so good offers get missed.
2. **No "new" awareness** — when offers do refresh, there is no signal telling the user *which* offers are new since they last looked. There is no notification and no dashboard cue.

Users want a once-a-day automatic refresh, a push when new offers arrive, and a visible cue (dashboard banner + per-offer marker) so they can jump into the Deals tab and triage the new ones by pinning or archiving.

## Goal

1. **Daily auto-refresh** of deals, once per day, at a company-configured local time.
2. **Push notification** when the scheduled refresh brings in genuinely new offers ("5 neue Angebote — REWE, Lidl …"). Opt-in per user. Manual refreshes never push.
3. **Dashboard banner** ("N neue Angebote") linking into the Deals tab.
4. **"NEU" marker** on new offers inside the Deals tab. An offer stays "new/unhandled" until the user **pins or archives** it (inbox model). When the user has handled all of them, the banner disappears on its own.
5. Available on **both** the PWA and the native iOS app.

## Non-Goals

- Real-time deal alerts (this is a once-a-day digest, like low-stock).
- Per-user push targeting of *which* offers are new (v1 push is a company-level "N new offers today" — the per-user inbox count drives the banner/markers instead).
- Changing how deals are fetched, matched, scored, or cached (we add tracking *around* the existing `deal-search` write path).
- Re-flagging an offer that left the cache and later returned (keeps its original first-seen; acceptable).
- A bulk "mark all as handled" action (the baseline mechanism below means there is no day-one backlog, so this is deferred).

## Key design decisions (agreed with user)

| Decision | Choice |
|---|---|
| Clients | PWA **and** native iOS |
| "New" semantics | **Inbox model**: new until the user pins **or** archives the offer |
| Refresh scheduling | **Opt-in per company** + configurable local hour (`deals_refresh_hour`), mirroring the low-stock daily push |
| Push behaviour | **Opt-in per user** (`notification_preferences` type `new_deals`); fires only on the **scheduled** run and only when ≥1 genuinely-new offer arrived |

## Core challenge & solution

`deal_cache` is **fully deleted and rewritten on every refresh** (`deal-search` does `DELETE all for company` then `INSERT`). So `deal_cache.id` and `deal_cache.created_at` are **not stable** and cannot tell us what is "new". The stable identity of an offer is `(retailer, offer_id)`.

We add two small **persistent** tables that survive cache rewrites:

### `deal_offer_first_seen`
Records, per company, when each distinct offer first ever appeared in the cache.

```
deal_offer_first_seen (
  company_id    uuid        not null references companies(id) on delete cascade,
  retailer      text        not null,
  offer_id      text        not null,
  first_seen_at timestamptz not null default now(),
  primary key (company_id, retailer, offer_id)
)
```

`deal-search` stamps this on **every** write (manual or scheduled) via `INSERT … ON CONFLICT DO NOTHING` — so `first_seen_at` is set exactly once per offer and never moves.

### `deal_user_seen`
A per-user **baseline** so the rollout does not retroactively mark the entire existing catalog as "new".

```
deal_user_seen (
  user_id     uuid        not null references auth.users(id) on delete cascade,
  company_id  uuid        not null references companies(id) on delete cascade,
  baseline_at timestamptz not null default now(),
  primary key (user_id, company_id)
)
```

The baseline row is created lazily (default `now()`) the first time we compute the new-deals set for a user. Offers whose `first_seen_at <= baseline_at` are treated as "already known" for that user → **no day-one backlog**, and new users joining later don't inherit the existing catalog either.

### "New / unhandled" definition

For user `U` in company `C`, an offer is **new/unhandled** iff:

- it is present in the current `deal_cache` for `C` (distinct `(retailer, offer_id)`) and still valid — `valid_until IS NULL OR valid_until >= current_date`, **and**
- `first_seen_at > baseline_at(U)`, **and**
- there is **no** `deal_user_state` row for `(U, C, retailer, offer_id)` with `pinned_at IS NOT NULL` **or** `archived_at IS NOT NULL`.

> Validity note: `deal-search` writes **all** matched rows including ones whose `valid_until` is already past (the validity filter only guards the cache-*hit read*, not the write). Without the `valid_until` clause the RPC could flag an expired-but-still-cached offer as "new". The frontend list does not filter on `valid_until` today, so the badge set (new + valid) is a strict subset of the visible list — acceptable; the banner count will never exceed what's shown.

Pinning or archiving therefore drops the offer out of the "new" set automatically — reusing the existing `deal_user_state` table, no extra per-offer tracking needed. Offers that expire/leave the cache stop counting automatically because we only intersect with the *current* cache.

## Approach

### 1. Database migration (single additive, idempotent file)

Mind the **migration-immutability rule**: one new migration file with a later timestamp, all idempotent ops (`CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, `DROP … IF EXISTS` then create).

- `ALTER TABLE companies ADD COLUMN IF NOT EXISTS deals_refresh_hour smallint` — nullable, `CHECK (deals_refresh_hour BETWEEN 0 AND 23)`, `NULL` = disabled.
- `deal_offer_first_seen` table (above) + RLS: `ENABLE ROW LEVEL SECURITY`; SELECT policy for authenticated company members (`company_id = my_company_id()`). No authenticated INSERT/UPDATE/DELETE policy — writes happen via the service-role client inside `deal-search`.
- `deal_user_seen` table (above) + RLS: SELECT policy for the user's own row (`user_id = auth.uid()`). **No authenticated INSERT/UPDATE policy is needed** — the baseline row is written only by the `SECURITY DEFINER` RPC below, which bypasses RLS. (Adding write policies would be harmless dead code; omit them.)
- **Backfill**: `INSERT INTO deal_offer_first_seen (company_id, retailer, offer_id) SELECT DISTINCT company_id, retailer, offer_id FROM deal_cache ON CONFLICT DO NOTHING` (first_seen defaults to `now()`), so existing offers get a baseline.
- **RPCs** (both `SECURITY DEFINER`, `SET search_path = public, extensions` — the project rule; they don't call pgcrypto so `public` alone would suffice, but keep the explicit form). `auth.uid()` inside a `SECURITY DEFINER` PostgREST RPC is a confirmed working pattern here (`my_company_id()` itself is such a function):
  - `get_new_deal_keys()` → `TABLE(retailer text, offer_id text)`: ensures the caller's `deal_user_seen` baseline row exists via `INSERT … ON CONFLICT (user_id, company_id) DO NOTHING` (must be `DO NOTHING` so concurrent dashboard + deals-page loads don't race), then returns the new/unhandled keys per the definition above for `auth.uid()` + `my_company_id()`.
  - `get_new_deals_count()` → `int`: `SELECT count(*) FROM get_new_deal_keys()`. Single source of truth; used by the dashboard banner.
- **Dispatcher + cron** (mirror the proven `20260528120000_low_stock_daily_push.sql` structure — the `DO $$` guard around `cron.unschedule`/`cron.schedule`, the `current_setting(..., true)` reads, the `SECURITY DEFINER` + `search_path`):
  - `dispatch_deal_refresh()` `SECURITY DEFINER`: reads `app.settings.supabase_url` + `app.settings.service_role_key` via `current_setting(..., true)`. **These GUCs are not set by any migration** — they are written by `Docker/setup.sh` / `Docker/update.sh` (`ALTER DATABASE postgres SET app.settings.…`) and merely *consumed* by `20260528120000`. Guard: if either is NULL, `RAISE WARNING` and `RETURN` (same as low-stock). Selects companies where `deals_enabled = true AND deals_refresh_hour IS NOT NULL AND deals_refresh_hour = EXTRACT(hour FROM (now() AT TIME ZONE COALESCE(timezone,'Europe/Berlin')))::int`; for each, `net.http_post` to `{url}/functions/v1/deal-search` with `Authorization: Bearer {service_role_key}` and body `{ "company_id": <id>, "scheduled": true }`.
  - **Deliberate divergence from low-stock**: the low-stock dispatcher keys *only* on its hour column; we additionally gate on `deals_enabled = true` (a company with deals off should never be auto-refreshed). This is intentional, not a copy error.
  - `cron.schedule('deal_daily_refresh', '0 * * * *', $$ select public.dispatch_deal_refresh(); $$)`, wrapped in the same `DO $$` block that guards on `pg_cron` presence and unschedules-if-exists first (idempotent). On a dev DB without `pg_cron` preloaded, this `RAISE WARNING`s and skips scheduling — the function + columns are still created (identical to low-stock's dev behaviour).

### 2. `deal-search` edge function changes (backward compatible)

- **Scheduled/service mode** (new, optional): read `company_id` + `scheduled` from the body first, then **branch on auth before the existing `getUser()` 401**. The function today does `getUser(token)` and returns 401 immediately on failure (`deal-search/index.ts:~278-285`); a service-role bearer is not a user JWT, so that path would 401. Add — *ahead* of the JWT path — a check `token === Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') && company_id` → resolve the company directly from `company_id`, skip `getUser`, force refresh. This is the exact pattern already used by `send-device-config/index.ts:~107` and `trigger-ota/index.ts:~23` (they pass `company_id` via header; body is fine here, just read it before the auth decision). Existing user-JWT calls (`{ forceRefresh }`) fall through unchanged.
- **Always**: after computing the offer set for this run, stamp `deal_offer_first_seen` **once over the de-duplicated union of `(retailer, offer_id)`** across both `productDealRows` and `keywordDealRows` (the same offer can appear in both batches; stamping per-batch would double-count or miss a keyword-only offer). Use `.upsert(rows, { onConflict: 'company_id,retailer,offer_id', ignoreDuplicates: true }).select('retailer, offer_id')` — `ignoreDuplicates` = `ON CONFLICT DO NOTHING`, and chaining `.select()` returns **only the rows actually inserted** (confirmed idiom: `confirm-payment`, `subscribe-restock`). The count of returned distinct keys = offers seen for the first time this run (`newCount`). Runs for both manual and scheduled refreshes (so `first_seen_at` is always maintained). Note `deal_offer_first_seen` has no pre-DELETE, so the upsert/ignoreDuplicates form is required (unlike the existing plain `.insert()` into `deal_cache`, which relies on the per-company DELETE first).
- **Scheduled mode only**: if `newCount > 0`, send a push via `sendPushToUsers(adminClient, company_id, 'new_deals', payloadBuilder)`. Build the body with the **per-user-locale pattern from `mqtt-webhook/index.ts:~505-537`** (a `(locale) => PushPayload` builder using `t(locale)` from `_shared/notification-i18n.ts`) — **not** `check-low-stock`, which is hardcoded English. Add two new keys to `_shared/notification-i18n.ts` (title + body, en/de), e.g. body "{n} neue Angebote — {retailers}". `data.url = '/deals'`. Manual refreshes never push.
- `sendPushToUsers(adminClient, companyId, type, payload)` signature confirmed at `web-push.ts:~585`. `deal-search` already runs under the global `[edge_runtime.secrets]` block (`config.toml:~365-383`) so it already sees VAPID/FCM/APNs — no per-function secret change needed.

### 3. Frontend (PWA)

- `useDeals.ts`: add `fetchNewDealKeys()` calling `get_new_deal_keys()` → `Set<"retailer::offer_id">`; expose `isNew(deal)` (`set.has(key)`) and `newDealsCount` (`set.size`). After a pin/archive succeeds, drop that key from the set (it is no longer "new") or re-fetch.
- `/deals/index.vue`: render a "NEU" badge on cards whose key is in the new set; optionally a "nur neue" quick filter / sort-new-first.
- Dashboard `index.vue`: a small banner card (reusing the existing alert/insight banner styling) shown when `get_new_deals_count() > 0` and deals are enabled, linking to `/deals`. Keep it light: call the count RPC directly and read `deals_enabled` with a cheap single-column `companies` select (it currently only comes *from* `useDeals().loadSettings()` — avoid pulling the whole deals machinery into the dashboard).
- `/settings`: a `deals_refresh_hour` selector (Off + 0–23) next to the existing deals settings. The hour is interpreted against `companies.timezone` (default `Europe/Berlin`, shared with low-stock) — label the picker with the actual timezone so it's clear, and note that the existing low-stock timezone control and this share `companies.timezone`. Plus a `new_deals` toggle in the notification-preferences UI.

### 4. Native iOS (`ios/VMflow/`)

- `DealsViewModel`: fetch the new-key set via the `get_new_deal_keys()` RPC; expose `isNew`; show a "NEU" badge in the deals list; refresh the set after pin/archive.
- Dashboard view: banner when `get_new_deals_count() > 0`, tapping navigates to the Deals tab.
- Settings: `deals_refresh_hour` picker + `new_deals` notification toggle. The iOS notification-type list is a **hardcoded Swift array** (`ios/VMflow/Services/NotificationService.swift:~63-85`, currently `sale` / `low_stock` / `inbox`) — adding the toggle means appending a `new_deals` entry there (localized label/description/icon), in addition to the web preferences UI.
- Push already reaches iOS via APNs through `sendPushToUsers`; the server respects the `new_deals` preference.

## Backward compatibility

- All DB changes are additive: new tables, one nullable column, new RPCs, additive cron job. Existing `deal_cache` / `deal_user_state` are untouched.
- `deal-search` new params are optional; existing frontend calls keep working.
- `new_deals` is a new `notification_preferences` type; absence defaults to enabled (existing opt-in-by-default design).
- Firmware is unaffected (backend + clients only).
- Migration is idempotent and immutable-safe (new file, later timestamp).

## Two environments (Prod Docker + Dev CLI)

- The migration runs in both: prod via `Docker/update.sh`, dev via `supabase migration up` (run the CLI with `--workdir Docker/supabase` per the known `.env` parse quirk).
- `pg_cron` settings (`app.settings.supabase_url`, `app.settings.service_role_key`) are **not** set by any migration — they are written by `Docker/setup.sh` (line ~174-175) and `Docker/update.sh` (line ~259-260) via `ALTER DATABASE`, and consumed by the low-stock dispatcher (`20260528120000`) and now by `dispatch_deal_refresh()`. They are reused as-is; no new settings needed. **Dev caveat**: a fresh `supabase start` DB has neither these GUCs nor (usually) `pg_cron` preloaded, so the scheduled path is prod-only — locally, test by invoking `select public.dispatch_deal_refresh();` (or calling `deal-search` with the service-role key + `company_id` directly).
- `deal-search` Web-Push secrets (VAPID / FCM / APNs) are global `edge_runtime` secrets (dev `config.toml [edge_runtime.secrets]:~365-383`) / docker-compose env (prod). `deal-search` already has `verify_jwt = false` and a `[functions.deal-search]` entry (`config.toml:~570-574`) and runs under the global secrets — no per-function secret change expected.
- No new edge function is added (the dispatcher is SQL; we reuse `deal-search`), so no new `config.toml [functions.*]` entry is needed.

## Testing

- **Edge (Deno):** unit-test the pure pieces — computing `newCount` from the `RETURNING` set and building the summary string ("N neue Angebote — REWE, Lidl …") from a list of new offers.
- **SQL:** verify `get_new_deal_keys()` honours the baseline and the pinned/archived exclusion; verify `dispatch_deal_refresh()` hour/timezone selection (logic mirrors the trusted low-stock dispatcher).
- **Frontend (Vitest):** `isNew` / `newDealsCount` from a given key set; banner visibility gated on count > 0 and deals enabled.
- **iOS:** lightweight check that the badge/banner reflect the RPC results.
- Manual end-to-end: set `deals_refresh_hour` to the current local hour, confirm the cron dispatch triggers a refresh, a `new_deals` push is sent only when new offers arrive, the banner appears, and pinning/archiving all new offers clears it.

## Open questions / future

- Optional "mark all as handled" bulk action (deferred; baseline removes the day-one need).
- Returning offers (left the cache, came back) keep their original `first_seen_at` and won't re-flag — accepted for v1.

(The push-localization question is resolved: use the `mqtt-webhook` per-locale builder + new `_shared/notification-i18n.ts` keys, per §Approach.2.)

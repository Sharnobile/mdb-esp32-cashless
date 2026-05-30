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

- it is present in the current `deal_cache` for `C` (distinct `(retailer, offer_id)`), **and**
- `first_seen_at > baseline_at(U)`, **and**
- there is **no** `deal_user_state` row for `(U, C, retailer, offer_id)` with `pinned_at IS NOT NULL` **or** `archived_at IS NOT NULL`.

Pinning or archiving therefore drops the offer out of the "new" set automatically — reusing the existing `deal_user_state` table, no extra per-offer tracking needed. Offers that expire/leave the cache stop counting automatically because we only intersect with the *current* cache.

## Approach

### 1. Database migration (single additive, idempotent file)

Mind the **migration-immutability rule**: one new migration file with a later timestamp, all idempotent ops (`CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, `DROP … IF EXISTS` then create).

- `ALTER TABLE companies ADD COLUMN IF NOT EXISTS deals_refresh_hour smallint` — nullable, `CHECK (deals_refresh_hour BETWEEN 0 AND 23)`, `NULL` = disabled.
- `deal_offer_first_seen` table (above) + RLS: `ENABLE ROW LEVEL SECURITY`; SELECT policy for authenticated company members (`company_id = my_company_id()`). No authenticated INSERT/UPDATE/DELETE policy — writes happen via the service-role client inside `deal-search`.
- `deal_user_seen` table (above) + RLS: authenticated users may SELECT/INSERT/UPDATE only their own row (`user_id = auth.uid() AND company_id = my_company_id()`).
- **Backfill**: `INSERT INTO deal_offer_first_seen (company_id, retailer, offer_id) SELECT DISTINCT company_id, retailer, offer_id FROM deal_cache ON CONFLICT DO NOTHING` (first_seen defaults to `now()`), so existing offers get a baseline.
- **RPCs** (both `SECURITY DEFINER`, `SET search_path = public, extensions`):
  - `get_new_deal_keys()` → `TABLE(retailer text, offer_id text)`: ensures the caller's `deal_user_seen` baseline row exists (insert `now()` if missing), then returns the new/unhandled keys per the definition above for `auth.uid()` + `my_company_id()`.
  - `get_new_deals_count()` → `int`: `SELECT count(*) FROM get_new_deal_keys()`. Single source of truth; used by the dashboard banner.
  - Both rely on `my_company_id()` / the user-state join; document the lazy-baseline write side effect.
- **Dispatcher + cron** (mirror `20260528120000_low_stock_daily_push.sql` exactly):
  - `dispatch_deal_refresh()` `SECURITY DEFINER`: reads `app.settings.supabase_url` + `app.settings.service_role_key` (already set up by the low-stock cron migration `20260527000000`); selects companies where `deals_enabled = true AND deals_refresh_hour IS NOT NULL AND deals_refresh_hour = EXTRACT(hour FROM (now() AT TIME ZONE COALESCE(timezone,'Europe/Berlin')))::int`; for each, `net.http_post` to `{url}/functions/v1/deal-search` with `Authorization: Bearer {service_role_key}` and body `{ "company_id": <id>, "scheduled": true }`.
  - `cron.schedule('deal_daily_refresh', '0 * * * *', $$ select public.dispatch_deal_refresh(); $$)`, guarded on `pg_cron` presence and idempotent (unschedule-if-exists then schedule).

### 2. `deal-search` edge function changes (backward compatible)

- **Scheduled/service mode** (new, optional): if the request carries the service-role key **and** `company_id` in the body, resolve the company directly from `company_id` instead of from a user JWT, and force a refresh. Existing user-JWT calls (`{ forceRefresh }`) are unchanged.
- **Always**: after computing the offer set for this run, stamp `deal_offer_first_seen` via `INSERT … ON CONFLICT DO NOTHING RETURNING retailer, offer_id`. The number of returned rows = offers seen for the first time this run (`newCount`). This runs for both manual and scheduled refreshes (so `first_seen_at` is always maintained).
- **Scheduled mode only**: if `newCount > 0`, send a push via `sendPushToUsers(adminClient, company_id, 'new_deals', payload)`. Payload summarises the new offers ("N neue Angebote — <top retailers>") with `data.url = '/deals'`, following the same per-user localization approach `check-low-stock` already uses. Manual refreshes never push.
- Ensure `deal-search` can import `_shared/web-push.ts` and has the Web-Push secrets available (they are global `edge_runtime` secrets / docker-compose env, so all functions see them — to be verified).

### 3. Frontend (PWA)

- `useDeals.ts`: add `fetchNewDealKeys()` calling `get_new_deal_keys()` → `Set<"retailer::offer_id">`; expose `isNew(deal)` (`set.has(key)`) and `newDealsCount` (`set.size`). After a pin/archive succeeds, drop that key from the set (it is no longer "new") or re-fetch.
- `/deals/index.vue`: render a "NEU" badge on cards whose key is in the new set; optionally a "nur neue" quick filter / sort-new-first.
- Dashboard `index.vue`: a small banner card (reusing the existing alert/insight banner styling) shown when `get_new_deals_count() > 0` and deals are enabled, linking to `/deals`. Lightweight — uses the count RPC, not the full deals machinery.
- `/settings`: a `deals_refresh_hour` selector (Off + 0–23 in company timezone) next to the existing deals settings; a `new_deals` toggle in the notification-preferences UI.

### 4. Native iOS (`ios/VMflow/`)

- `DealsViewModel`: fetch the new-key set via the `get_new_deal_keys()` RPC; expose `isNew`; show a "NEU" badge in the deals list; refresh the set after pin/archive.
- Dashboard view: banner when `get_new_deals_count() > 0`, tapping navigates to the Deals tab.
- Settings: `deals_refresh_hour` picker + `new_deals` notification toggle (parity with PWA).
- Push already reaches iOS via APNs through `sendPushToUsers`; the server respects the `new_deals` preference.

## Backward compatibility

- All DB changes are additive: new tables, one nullable column, new RPCs, additive cron job. Existing `deal_cache` / `deal_user_state` are untouched.
- `deal-search` new params are optional; existing frontend calls keep working.
- `new_deals` is a new `notification_preferences` type; absence defaults to enabled (existing opt-in-by-default design).
- Firmware is unaffected (backend + clients only).
- Migration is idempotent and immutable-safe (new file, later timestamp).

## Two environments (Prod Docker + Dev CLI)

- The migration runs in both: prod via `Docker/update.sh`, dev via `supabase migration up` (run the CLI from `Docker/supabase` with `--workdir` per the known `.env` parse quirk).
- `pg_cron` settings (`app.settings.supabase_url`, `app.settings.service_role_key`) were established by the low-stock cron migration `20260527000000` and are reused as-is.
- `deal-search` Web-Push secrets (VAPID / FCM / APNs) are global `edge_runtime` secrets (dev `config.toml [edge_runtime.secrets]`) / docker-compose env (prod). Verify `deal-search` resolves them — no new per-function secret expected.
- No new edge function is added (the dispatcher is SQL; we reuse `deal-search`), so no new `config.toml [functions.*]` entry is needed.

## Testing

- **Edge (Deno):** unit-test the pure pieces — computing `newCount` from the `RETURNING` set and building the summary string ("N neue Angebote — REWE, Lidl …") from a list of new offers.
- **SQL:** verify `get_new_deal_keys()` honours the baseline and the pinned/archived exclusion; verify `dispatch_deal_refresh()` hour/timezone selection (logic mirrors the trusted low-stock dispatcher).
- **Frontend (Vitest):** `isNew` / `newDealsCount` from a given key set; banner visibility gated on count > 0 and deals enabled.
- **iOS:** lightweight check that the badge/banner reflect the RPC results.
- Manual end-to-end: set `deals_refresh_hour` to the current local hour, confirm the cron dispatch triggers a refresh, a `new_deals` push is sent only when new offers arrive, the banner appears, and pinning/archiving all new offers clears it.

## Open questions / future

- Optional "mark all as handled" bulk action (deferred; baseline removes the day-one need).
- Whether to localise the push body fully per-user (reuse whatever `check-low-stock` does today).
- Returning offers (left the cache, came back) keep their original `first_seen_at` and won't re-flag — accepted for v1.

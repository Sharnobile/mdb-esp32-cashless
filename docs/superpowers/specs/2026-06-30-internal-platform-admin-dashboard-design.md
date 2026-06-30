# Internal Platform-Admin Dashboard — Design

**Date:** 2026-06-30
**Status:** Approved (design), pending spec review
**Author:** Lucien Kerl (with Claude)

## 1. Problem & Goal

The operator needs an **internal-only, cross-company overview** of the whole
deployment:

- How many companies and users are registered (global totals).
- How many vending machines / devices each company has.
- How active each company is (sales over time, devices online, last activity).
- Drill-down per company (members, devices, recent sales).

This is a **platform-operator ("super admin") view** that deliberately crosses
the per-company multi-tenancy boundary. Today the system has **no such concept**:
the only roles are per-company `admin` / `viewer`, and every table is locked
behind RLS via `my_company_id()` / `i_am_admin()`
(`Docker/supabase/migrations/20260228000000_multitenancy.sql:61-70`).

## 2. Access-Control Decision

**Context:** External tenant companies log into the same frontend over the
internet. Therefore a network-level (LAN/VPN) restriction **alone is not safe** —
a logged-in customer could reach an `/admin` route and trigger cross-company
data exposure.

**Decision: a real platform-admin gate is the primary protection.** LAN/VPN
restriction is a documented secondary hardening layer (ops, not code).

The gate is enforced **inside the database** (see §3) so there is no code path
that returns cross-company data to a non-platform-admin, regardless of how the
endpoint is reached.

## 3. Architecture — Self-Guarding `SECURITY DEFINER` RPCs

The frontend calls Postgres RPCs directly with the **normal user JWT** (same
pattern as the existing `get_machine_insights_kpis` / `get_machine_product_kpis`
analytics RPCs). Each RPC:

1. Calls `is_platform_admin()` first and **raises an exception if false**.
2. Then aggregates across **all** companies using its `SECURITY DEFINER`
   privilege (which bypasses RLS).

Because the authorization check lives *inside* the function, the function cannot
be abused to read another company's data.

### Rejected alternatives

- **Service-role edge function** (`/functions/v1/admin-stats`): works, but adds
  a second auth path + boilerplate. The RPC approach matches existing analytics
  and needs no new function wiring (`config.toml`, `deno.json`, etc.).
- **`OR is_platform_admin()` added to every table's RLS policy**: too broad,
  touches many policies, easy to leak (cf. the `machine_insights_*`
  `USING(true)` cross-company-leak incident). Rejected.

## 4. Data Layer (one new migration, fully additive)

New migration file `Docker/supabase/migrations/YYYYMMDDHHMMSS_platform_admin.sql`.
All objects are new; **no existing RLS policy, table, firmware, or MQTT contract
is touched.** Idempotent operations (`CREATE TABLE IF NOT EXISTS`,
`CREATE OR REPLACE FUNCTION`).

### 4.1 `platform_admins` table

```sql
create table if not exists public.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.platform_admins enable row level security;
-- No public policies: the table is only ever read via is_platform_admin()
-- (SECURITY DEFINER). Normal authenticated users cannot select it.
```

### 4.2 `is_platform_admin()` helper

```sql
create or replace function public.is_platform_admin()
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.platform_admins where user_id = auth.uid()
  );
$$;
```

`SECURITY DEFINER` + explicit `search_path` per the project rule for definer
functions. `set search_path = public` is sufficient here because the function
calls no extension (pgcrypto) functions and qualifies its one table as
`public.platform_admins`. *(The latest project helpers in `20260418000000` use
`set search_path = ''` with fully-qualified names; either is safe. The
aggregation RPCs in §4.3/§4.4 follow the same rule — explicit `search_path`,
fully-qualified `public.` table references.)* Mirrors the `my_company_id()` /
`i_am_admin()` helper style.

### 4.3 `get_platform_overview(p_days int default 30)`

Self-guards (`if not public.is_platform_admin() then raise exception ... end if;`),
then returns a single JSON object:

- **`totals`**: `company_count`, `user_count` (`COUNT(DISTINCT user_id)` — see
  definition below), `machine_count` (`vendingMachine`), `device_count`
  (`embeddeds`), `devices_online`.
- **`companies`**: array, one row per company:
  - `company_id`, `name`
  - `user_count`, `admin_count`, `viewer_count` (from `organization_members`)
  - `machine_count` (`vendingMachine`), `device_count` (`embeddeds`),
    `devices_online`
  - `sales_today_count` / `sales_today_revenue`,
    `sales_7d_count` / `sales_7d_revenue`,
    `sales_30d_count` / `sales_30d_revenue` (window driven by `p_days`; the
    fixed today/7d/30d buckets are computed inside the function)
  - `last_sale_at` (max `sales.created_at` across the company's devices)
  - `last_device_seen_at` (max `embeddeds.status_at`)

**Definitions:**
- *Online* = `embeddeds.status IS NOT NULL AND embeddeds.status <> 'offline'` —
  **deliberately matching the existing dashboard** (`pages/index.vue:373` counts
  `status && status !== 'offline'`, which also keeps transient states like
  `ota_updating`/`ota_success` counted as online). Using the same predicate
  ensures the platform "devices online" KPI never silently disagrees with the
  per-company dashboard.
- *Last device contact* = `embeddeds.status_at` (heartbeat, ~5 min cadence).
- *Revenue* = `SUM(sales.item_price)` — **`item_price` is EUR, never divide by
  100** (project rule).
- **Attribution paths** (both `vendingMachine.company` and `embeddeds.company`
  exist and can diverge, so name the join explicitly):
  - Machines → `vendingMachine.company`.
  - Devices → `embeddeds.company`.
  - Sales → `sales.embedded_id → embeddeds.company`.
- **`user_count`**: globally `COUNT(DISTINCT organization_members.user_id)` (a
  user belonging to two companies counts once globally). Per-company counts are
  `COUNT(*)` within each company and **may overlap**, so the per-company
  `user_count` values are not guaranteed to sum to the global total.

Returning a single JSON object (rather than a `TABLE`) keeps the multi-level
totals + per-company array in one round-trip and one typed payload, consistent
with how the insights RPCs return composite JSON.

### 4.4 `get_platform_company_detail(p_company_id uuid)`

Self-guards, then returns a JSON object for the drill-down view of one company:

- `company`: `id`, `name`, `created_at`
- `members`: array of `{ user_id, email, role, joined_at }`
  (email primarily from `public.users.email` — backfilled + trigger-maintained
  by migration `20260301700000_user_email.sql`; fall back to `auth.users.email`
  only if a `public.users` row is missing)
- `devices`: array of `{ embedded_id, subdomain, mac_address, status,
  status_at, online_since, firmware_version, machine_name }`
  (`machine_name` joined from `vendingMachine` where present)
- `recent_sales`: array of the most recent N (e.g. 50) sales
  `{ created_at, item_price, item_number, channel, machine_name }`

### 4.5 Bootstrap seed

The migration seeds the operator(s) into `platform_admins` idempotently by
email lookup, so a fresh apply makes the operator a platform admin without a
manual step:

```sql
insert into public.platform_admins (user_id)
select id from auth.users
where email in ('lucien@kerl-handel.de', 'steven@kerl-handel.de')
on conflict (user_id) do nothing;
```

*(Emails to be confirmed by the user before writing the migration. On installs
where those emails don't exist, the insert is simply a no-op — additional
platform admins can be added later with a one-line `insert`.)*

## 5. Frontend Layer (additive)

Nuxt 4 app under `management-frontend/app/`.

### 5.1 Composable `usePlatformAdmin()`

- `fetchOverview(days?)` → calls `get_platform_overview`, caches in `useState`.
- `fetchCompanyDetail(companyId)` → calls `get_platform_company_detail`.
- `isPlatformAdmin` boolean state, resolved once (via a cheap RPC
  `is_platform_admin()` exposed to `authenticated`, or derived from a successful
  overview call). Used for nav + route guard.
- Results are typed manually with `as {...}[]` casts (project has **no generated
  DB types**).

### 5.2 Route guard `middleware/platform-admin.ts`

Applied to `/admin/**`. Redirects to `/` (or 404) if `isPlatformAdmin` is false.
This is a UX guard; the DB self-guard is the real security boundary.

### 5.3 Pages

- **`/admin/platform`** — overview:
  - KPI cards: total companies, users, machines, devices, devices online.
  - Sortable company table (reuse shadcn table + `useTableSort`): name, users,
    machines, devices online/total, sales 30d (count + revenue via
    `formatCurrency`), last activity (`timeAgo`). Each row links to the detail
    page.
- **`/admin/platform/[companyId]`** — drill-down: company header + KPIs, members
  table, devices table (with online badge + `timeAgo` last seen), recent sales
  list.

### 5.4 Navigation

`AppSidebar.vue` gains a "Plattform" entry (own group or appended to the
existing admin-only "Technical" group) rendered **only when `isPlatformAdmin`**
is true — analogous to the existing `role.value === 'admin'` gating
(`AppSidebar.vue:115-136`).

### 5.5 i18n

All new UI strings added to both `en` and `de` locale files, consistent with the
existing `@nuxtjs/i18n` setup.

## 6. Network Layer (LAN/VPN) — ops, not code

The platform-admin gate is the primary protection. As an **optional** secondary
hardening step, the operator may restrict `/admin/**` (and/or the RPC calls) to
internal IP ranges / VPN at the reverse proxy. Documented in the spec; no code
change required. This satisfies the "nur intern erreichbar" intent as
defense-in-depth on top of the auth gate.

## 7. Backward Compatibility

- New table + new RPCs + new pages = **purely additive**.
- No change to existing RLS policies, edge functions, firmware, MQTT topics, or
  payload formats.
- Migration uses idempotent operations and a no-op-safe seed → safe on every
  existing install via `update.sh` / `supabase migration up`, and a no-op on
  fresh installs that already received the objects in order.
- Old/other clients (iOS, Android, existing PWA pages) are unaffected.

## 8. Scope Guardrails (YAGNI)

- **Read-only + drill-down only.** No destructive/management actions (block/
  delete company, remove user) in this iteration.
- No new edge function, no `/api/v1` exposure (cross-company stats must not be
  reachable via tenant API keys).
- No real-time subscriptions for the admin view — on-demand fetch + manual
  refresh is sufficient.

## 9. Out of Scope / Future

- Platform-admin management UI (adding/removing platform admins via the
  dashboard) — for now done via SQL.
- Management actions (suspend/delete company, remove member).
- Historical trend charts beyond the today/7d/30d buckets.
- Exposing platform stats over `/api/v1` or to the iOS/Android apps.

## 10. Open Questions for Planning

1. Confirm the operator email(s) for the bootstrap seed (§4.5).
2. Confirm `recent_sales` limit (default 50) and whether the company table
   should default-sort by 30-day revenue or last activity.
3. Decide whether `is_platform_admin()` is also exposed directly to the frontend
   for the nav check, or inferred from a successful overview call.

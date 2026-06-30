# Internal Platform-Admin Dashboard Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an internal, cross-company "platform admin" overview (global totals + per-company activity + per-company drill-down), gated by a `platform_admins` allow-list enforced inside self-guarding `SECURITY DEFINER` Postgres RPCs.

**Architecture:** A new additive DB migration adds a `platform_admins` table, an `is_platform_admin()` helper, and two self-guarding aggregation RPCs. The Nuxt frontend gains a `usePlatformAdmin()` composable (with unit-tested pure helpers), a route-guard middleware, two pages (`/admin/platform`, `/admin/platform/[companyId]`), a conditional sidebar entry, and en/de strings. The DB self-guard is the real security boundary; the route guard and LAN/VPN restriction are secondary layers.

**Tech Stack:** PostgreSQL (Supabase migrations, plpgsql `SECURITY DEFINER` RPCs returning `json`), Nuxt 4 + TypeScript + Vue 3 (`app/` dir), `@nuxtjs/supabase`, shadcn-nuxt, `@nuxtjs/i18n`, Vitest, and the repo's `Docker/supabase/tests/*.test.sql` psql harness.

**Spec:** `docs/superpowers/specs/2026-06-30-internal-platform-admin-dashboard-design.md`

---

## File Structure

**Create:**
- `Docker/supabase/migrations/20260630000000_platform_admin.sql` — table + helper + RPCs + grants + seed
- `Docker/supabase/tests/platform_admin.test.sql` — SQL harness tests (auth gate + aggregation)
- `management-frontend/app/composables/usePlatformAdmin.ts` — data fetch + pure helpers + types
- `management-frontend/app/composables/__tests__/usePlatformAdmin.test.ts` — unit tests for pure helpers
- `management-frontend/app/middleware/platform-admin.ts` — route guard for `/admin/**`
- `management-frontend/app/pages/admin/platform/index.vue` — overview page (KPI cards + company table)
- `management-frontend/app/pages/admin/platform/[companyId].vue` — drill-down page

**Modify:**
- `management-frontend/app/components/AppSidebar.vue` — conditional "Plattform" nav entry
- `management-frontend/i18n/locales/en.json` — English strings
- `management-frontend/i18n/locales/de.json` — German strings

**Conventions confirmed from the codebase (follow exactly):**
- RPCs: `create or replace function public.<name>(...) returns json language plpgsql security definer set search_path = public`, then `grant execute ... to authenticated; ... to service_role;` (pattern: `Docker/supabase/migrations/20260317000000_machine_insights_rpc.sql`).
- Frontend RPC call: `(supabase as any).rpc('name', { p_x: ... })` returning `{ data, error }`; cast results with `as {...}` (no generated DB types).
- Composables: `useState('<key>', () => …)` for shared cache; import from `#imports`.
- Pages opt into auth via `definePageMeta({ middleware: 'auth' })` (auth is NOT global). New pages use `definePageMeta({ middleware: ['auth', 'platform-admin'] })`.
- `sales.item_price` is **EUR** — never divide by 100.
- Online predicate (match existing dashboard `pages/index.vue:373`): `status IS NOT NULL AND status <> 'offline'`.
- Attribution: machines via `vendingMachine.company`; devices via `embeddeds.company`; sales via `sales.embedded_id → embeddeds.company`.

---

## Chunk 1: Database Layer

### Task 1: Migration — table, helper, RPCs, grants, seed

**Files:**
- Create: `Docker/supabase/migrations/20260630000000_platform_admin.sql`

> Latest existing migration is `20260629120000_cash_book_expense.sql`; `20260630000000` sorts after it. Migration is brand-new in this session, so it may be committed normally (the immutability hook only blocks files already on `origin/main`).

- [ ] **Step 1: Write the full migration file**

```sql
-- ============================================================================
-- Internal platform-admin dashboard.
-- Adds a cross-company operator allow-list + self-guarding SECURITY DEFINER
-- aggregation RPCs. Fully additive: no existing table/policy/RPC is modified.
-- ============================================================================

-- 1. Allow-list table -------------------------------------------------------
create table if not exists public.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.platform_admins enable row level security;
-- No policies on purpose: the table is only ever read via is_platform_admin()
-- (SECURITY DEFINER, runs as owner and bypasses RLS). Normal authenticated
-- users cannot select it. service_role keeps full access for admin scripts.
grant select, insert, delete on public.platform_admins to service_role;

-- 2. Membership helper ------------------------------------------------------
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

grant execute on function public.is_platform_admin() to authenticated, service_role;

-- 3. Cross-company overview -------------------------------------------------
-- p_days drives the configurable "window" bucket (default 30); today and 7d
-- buckets are fixed.
create or replace function public.get_platform_overview(p_days int default 30)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result json;
  v_window_start timestamptz := now() - (p_days || ' days')::interval;
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  with member_agg as (
    select company_id,
           count(*)                                  as user_count,
           count(*) filter (where role = 'admin')    as admin_count,
           count(*) filter (where role = 'viewer')   as viewer_count
    from public.organization_members
    group by company_id
  ),
  device_agg as (
    select company as company_id,
           count(*)                                                              as device_count,
           count(*) filter (where status is not null and status <> 'offline')    as devices_online,
           max(status_at)                                                        as last_device_seen_at
    from public.embeddeds
    where company is not null
    group by company
  ),
  machine_agg as (
    select company as company_id, count(*) as machine_count
    from public."vendingMachine"
    where company is not null
    group by company
  ),
  sales_agg as (
    select e.company as company_id,
           count(*) filter (where s.created_at >= date_trunc('day', now()))                      as sales_today_count,
           coalesce(sum(s.item_price) filter (where s.created_at >= date_trunc('day', now())), 0) as sales_today_revenue,
           count(*) filter (where s.created_at >= now() - interval '7 days')                      as sales_7d_count,
           coalesce(sum(s.item_price) filter (where s.created_at >= now() - interval '7 days'), 0) as sales_7d_revenue,
           count(*) filter (where s.created_at >= v_window_start)                                 as sales_window_count,
           coalesce(sum(s.item_price) filter (where s.created_at >= v_window_start), 0)           as sales_window_revenue,
           max(s.created_at)                                                                       as last_sale_at
    from public.sales s
    join public.embeddeds e on e.id = s.embedded_id
    where e.company is not null
    group by e.company
  ),
  companies_json as (
    select json_agg(row_to_json(c_row) order by lower(c_row.name)) as arr
    from (
      select
        c.id                                  as company_id,
        c.name,
        coalesce(m.user_count, 0)             as user_count,
        coalesce(m.admin_count, 0)            as admin_count,
        coalesce(m.viewer_count, 0)           as viewer_count,
        coalesce(mc.machine_count, 0)         as machine_count,
        coalesce(d.device_count, 0)           as device_count,
        coalesce(d.devices_online, 0)         as devices_online,
        coalesce(sa.sales_today_count, 0)     as sales_today_count,
        coalesce(sa.sales_today_revenue, 0)   as sales_today_revenue,
        coalesce(sa.sales_7d_count, 0)        as sales_7d_count,
        coalesce(sa.sales_7d_revenue, 0)      as sales_7d_revenue,
        coalesce(sa.sales_window_count, 0)    as sales_window_count,
        coalesce(sa.sales_window_revenue, 0)  as sales_window_revenue,
        sa.last_sale_at,
        d.last_device_seen_at
      from public.companies c
      left join member_agg  m  on m.company_id  = c.id
      left join device_agg  d  on d.company_id  = c.id
      left join machine_agg mc on mc.company_id = c.id
      left join sales_agg   sa on sa.company_id = c.id
    ) c_row
  )
  select json_build_object(
    'window_days', p_days,
    'totals', json_build_object(
      'company_count',  (select count(*) from public.companies),
      'user_count',     (select count(distinct user_id) from public.organization_members),
      'machine_count',  (select count(*) from public."vendingMachine"),
      'device_count',   (select count(*) from public.embeddeds),
      'devices_online', (select count(*) from public.embeddeds
                          where status is not null and status <> 'offline')
    ),
    'companies', coalesce((select arr from companies_json), '[]'::json)
  ) into v_result;

  return v_result;
end;
$$;

grant execute on function public.get_platform_overview(int) to authenticated, service_role;

-- 4. Per-company drill-down -------------------------------------------------
create or replace function public.get_platform_company_detail(p_company_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result json;
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;

  select json_build_object(
    'company', (
      select json_build_object('id', c.id, 'name', c.name, 'created_at', c.created_at)
      from public.companies c where c.id = p_company_id
    ),
    'members', coalesce((
      select json_agg(json_build_object(
        'user_id',  om.user_id,
        'email',    coalesce(pu.email, au.email),
        'role',     om.role,
        'joined_at', om.created_at
      ) order by om.created_at)
      from public.organization_members om
      left join public.users pu on pu.id = om.user_id
      left join auth.users  au on au.id = om.user_id
      where om.company_id = p_company_id
    ), '[]'::json),
    'devices', coalesce((
      select json_agg(json_build_object(
        'embedded_id',      e.id,
        'subdomain',        e.subdomain,
        'mac_address',      e.mac_address,
        'status',           e.status,
        'status_at',        e.status_at,
        'online_since',     e.online_since,
        'firmware_version', e.firmware_version,
        'machine_name',     vm.name
      ) order by e.subdomain)
      from public.embeddeds e
      left join public."vendingMachine" vm on vm.embedded = e.id
      where e.company = p_company_id
    ), '[]'::json),
    'recent_sales', coalesce((
      select json_agg(rs)
      from (
        select s.created_at, s.item_price, s.item_number, s.channel, vm.name as machine_name
        from public.sales s
        join public.embeddeds e on e.id = s.embedded_id
        left join public."vendingMachine" vm on vm.id = s.machine_id
        where e.company = p_company_id
        order by s.created_at desc
        limit 50
      ) rs
    ), '[]'::json)
  ) into v_result;

  return v_result;
end;
$$;

grant execute on function public.get_platform_company_detail(uuid) to authenticated, service_role;

-- 5. Bootstrap seed (idempotent; no-op where the email doesn't exist) --------
insert into public.platform_admins (user_id)
select id from auth.users
where email = 'lucien@kerl-handel.de'
on conflict (user_id) do nothing;
```

- [ ] **Step 2: Commit the migration**

```bash
git add Docker/supabase/migrations/20260630000000_platform_admin.sql
git commit -m "feat(platform-admin): migration — allow-list + cross-company RPCs"
```

### Task 2: SQL harness tests (auth gate + aggregation)

**Files:**
- Create: `Docker/supabase/tests/platform_admin.test.sql`
- Test runner: `Docker/supabase/tests/run-sql-tests.sh` (needs `supabase start`)

Pattern reference: `Docker/supabase/tests/get_product_detail_kpis.test.sql` (fake JWT via `set_config('request.jwt.claims', …, true)`, plain `ASSERT` in a rolled-back `BEGIN; … ROLLBACK;`).

- [ ] **Step 1: Write the test file**

```sql
-- Tests is_platform_admin gating + get_platform_overview / _company_detail.
-- Rolled back. Plain ASSERTs. Fake JWT for the authenticated path.
BEGIN;
SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company  uuid := gen_random_uuid();
  v_admin    uuid := gen_random_uuid();  -- platform admin
  v_other    uuid := gen_random_uuid();  -- normal user, NOT platform admin
  v_dev      uuid := gen_random_uuid();
  v_overview json;
  v_detail   json;
  v_raised   boolean := false;
BEGIN
  -- Fixtures
  INSERT INTO public.companies (id, name) VALUES (v_company, 'Acme');
  INSERT INTO auth.users (id, instance_id, email, created_at) VALUES
    (v_admin, '00000000-0000-0000-0000-000000000000', 'admin@test.local', now()),
    (v_other, '00000000-0000-0000-0000-000000000000', 'other@test.local', now());
  INSERT INTO public.users (id, company, email) VALUES
    (v_admin, v_company, 'admin@test.local'),
    (v_other, v_company, 'other@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role) VALUES
    (v_company, v_admin, 'admin'),
    (v_company, v_other, 'viewer');
  INSERT INTO public.embeddeds (id, company, status, status_at) VALUES
    (v_dev, v_company, 'online', now());
  INSERT INTO public."vendingMachine" (name, company, embedded) VALUES ('M1', v_company, v_dev);
  INSERT INTO public.sales (embedded_id, item_price, item_number, channel, created_at)
    VALUES (v_dev, 2.50, 11, 'mdb', now());

  -- Grant platform admin to v_admin only
  INSERT INTO public.platform_admins (user_id) VALUES (v_admin);

  -- Test 1: non-platform-admin is rejected
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_other)::text, true);
  BEGIN
    PERFORM public.get_platform_overview(30);
  EXCEPTION WHEN insufficient_privilege THEN  -- the function's errcode 42501
    v_raised := true;
  END;
  ASSERT v_raised, 'non-platform-admin must be rejected by get_platform_overview';
  RAISE NOTICE 'Test 1 passed: non-admin rejected';

  -- Test 2: is_platform_admin reflects membership
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  ASSERT public.is_platform_admin() = true,  'admin recognised';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_other)::text, true);
  ASSERT public.is_platform_admin() = false, 'non-admin not recognised';
  RAISE NOTICE 'Test 2 passed: is_platform_admin correct';

  -- Test 3: overview returns totals + the company row (as platform admin)
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  v_overview := public.get_platform_overview(30);
  ASSERT (v_overview->'totals'->>'company_count')::int >= 1,  'company_count >= 1';
  ASSERT (v_overview->'totals'->>'devices_online')::int >= 1, 'devices_online >= 1';
  ASSERT EXISTS (
    SELECT 1 FROM json_array_elements(v_overview->'companies') x
    WHERE (x->>'company_id') = v_company::text
      AND (x->>'user_count')::int = 2
      AND (x->>'machine_count')::int = 1
      AND (x->>'devices_online')::int = 1
      AND (x->>'sales_today_count')::int = 1
      AND (x->>'sales_today_revenue')::numeric = 2.50
  ), 'company row has correct aggregates';
  RAISE NOTICE 'Test 3 passed: overview aggregates correct';

  -- Test 4: drill-down returns members + devices + sales
  v_detail := public.get_platform_company_detail(v_company);
  ASSERT json_array_length(v_detail->'members') = 2,       'detail has 2 members';
  ASSERT json_array_length(v_detail->'devices') = 1,       'detail has 1 device';
  ASSERT json_array_length(v_detail->'recent_sales') = 1,  'detail has 1 recent sale';
  RAISE NOTICE 'Test 4 passed: company detail correct';

  RAISE NOTICE 'ALL platform_admin tests passed';
END $$;

ROLLBACK;
```

- [ ] **Step 2: Apply the migration to local dev**

Run: `cd Docker/supabase && supabase migration up`
Expected: applies `20260630000000_platform_admin.sql` with no error. (Do NOT run `supabase db reset` — project rule.)

> If `supabase migration up` is blocked by the known phantom migration `20260606000000` (see project memory), surface that to the user rather than working around it; it is out of scope for this plan.

- [ ] **Step 3: Run the SQL tests**

Run: `cd Docker/supabase && ./tests/run-sql-tests.sh` (or `PSQL=/opt/homebrew/opt/libpq/bin/psql ./tests/run-sql-tests.sh`)
Expected: `platform_admin.test.sql` prints `ALL platform_admin tests passed` and the runner reports success. Tests roll back, leaving no data.

- [ ] **Step 4: Commit**

```bash
git add Docker/supabase/tests/platform_admin.test.sql
git commit -m "test(platform-admin): SQL harness tests for gate + aggregation"
```

---

## Chunk 2: Frontend Data Layer

### Task 3: `usePlatformAdmin()` composable + pure helpers (TDD)

**Files:**
- Create: `management-frontend/app/composables/usePlatformAdmin.ts`
- Test: `management-frontend/app/composables/__tests__/usePlatformAdmin.test.ts`

The composable exposes two **pure, exported helpers** (unit-tested) plus the fetch functions (thin RPC wrappers). Pure helpers:
- `companyActivityLevel(lastSaleAt, now)` → `'active' | 'idle' | 'dead'` (active = sale within 7 days, idle = within 30 days, dead = older/never). Drives a colour-coded activity badge in the table — answers the user's "wie aktiv".
- `isDeviceOnline(status)` → mirrors the backend predicate for client-side device badges in the drill-down.

- [ ] **Step 1: Write the failing tests**

```ts
import { describe, it, expect } from 'vitest'
import { companyActivityLevel, isDeviceOnline } from '../usePlatformAdmin'

describe('companyActivityLevel', () => {
  const now = new Date('2026-06-30T12:00:00Z')

  it('returns active when last sale is within 7 days', () => {
    expect(companyActivityLevel('2026-06-28T12:00:00Z', now)).toBe('active')
  })
  it('returns idle when last sale is 8–30 days ago', () => {
    expect(companyActivityLevel('2026-06-10T12:00:00Z', now)).toBe('idle')
  })
  it('returns dead when last sale is older than 30 days', () => {
    expect(companyActivityLevel('2026-04-01T12:00:00Z', now)).toBe('dead')
  })
  it('returns dead when there was never a sale', () => {
    expect(companyActivityLevel(null, now)).toBe('dead')
  })
})

describe('isDeviceOnline', () => {
  it('treats online and transient non-offline states as online', () => {
    expect(isDeviceOnline('online')).toBe(true)
    expect(isDeviceOnline('ota_updating')).toBe(true)
  })
  it('treats offline and null/empty as not online', () => {
    expect(isDeviceOnline('offline')).toBe(false)
    expect(isDeviceOnline(null)).toBe(false)
    expect(isDeviceOnline('')).toBe(false)
  })
})
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd management-frontend && npx vitest run app/composables/__tests__/usePlatformAdmin.test.ts`
Expected: FAIL — `usePlatformAdmin` has no such exports yet.

- [ ] **Step 3: Implement the composable**

```ts
import { ref, useState, useSupabaseClient } from '#imports'

// ── Types (no generated DB types; cast manually) ──────────────────────────────
export interface PlatformTotals {
  company_count: number
  user_count: number
  machine_count: number
  device_count: number
  devices_online: number
}

export interface PlatformCompanyRow {
  company_id: string
  name: string
  user_count: number
  admin_count: number
  viewer_count: number
  machine_count: number
  device_count: number
  devices_online: number
  sales_today_count: number
  sales_today_revenue: number
  sales_7d_count: number
  sales_7d_revenue: number
  sales_window_count: number
  sales_window_revenue: number
  last_sale_at: string | null
  last_device_seen_at: string | null
}

export interface PlatformOverview {
  window_days: number
  totals: PlatformTotals
  companies: PlatformCompanyRow[]
}

export interface CompanyMember { user_id: string; email: string | null; role: string; joined_at: string }
export interface CompanyDevice {
  embedded_id: string; subdomain: number; mac_address: string | null
  status: string | null; status_at: string | null; online_since: string | null
  firmware_version: string | null; machine_name: string | null
}
export interface CompanySaleRow { created_at: string; item_price: number; item_number: number | null; channel: string | null; machine_name: string | null }
export interface CompanyDetail {
  company: { id: string; name: string; created_at: string } | null
  members: CompanyMember[]
  devices: CompanyDevice[]
  recent_sales: CompanySaleRow[]
}

export type ActivityLevel = 'active' | 'idle' | 'dead'

// ── Pure helpers (unit-tested) ────────────────────────────────────────────────
export function companyActivityLevel(lastSaleAt: string | null, now: Date = new Date()): ActivityLevel {
  if (!lastSaleAt) return 'dead'
  const ageMs = now.getTime() - new Date(lastSaleAt).getTime()
  const day = 86_400_000
  if (ageMs <= 7 * day) return 'active'
  if (ageMs <= 30 * day) return 'idle'
  return 'dead'
}

export function isDeviceOnline(status: string | null | undefined): boolean {
  return status != null && status !== '' && status !== 'offline'
}

// ── Composable ────────────────────────────────────────────────────────────────
export function usePlatformAdmin() {
  const supabase = useSupabaseClient()

  const overview = useState<PlatformOverview | null>('platform-overview', () => null)
  const isPlatformAdmin = useState<boolean>('is-platform-admin', () => false)
  const loading = ref(false)
  const error = ref('')

  async function fetchOverview(days = 30) {
    loading.value = true
    error.value = ''
    try {
      const { data, error: rpcError } = await (supabase as any).rpc('get_platform_overview', { p_days: days })
      if (rpcError) throw rpcError
      overview.value = data as PlatformOverview
      isPlatformAdmin.value = true
    } catch (err: any) {
      // A "not authorized" raise (errcode 42501) means the caller is not a platform admin.
      isPlatformAdmin.value = false
      error.value = err?.message ?? 'failed to load platform overview'
      throw err
    } finally {
      loading.value = false
    }
  }

  async function checkIsPlatformAdmin(): Promise<boolean> {
    try {
      const { data, error: rpcError } = await (supabase as any).rpc('is_platform_admin')
      if (rpcError) throw rpcError
      isPlatformAdmin.value = data === true
    } catch {
      isPlatformAdmin.value = false
    }
    return isPlatformAdmin.value
  }

  async function fetchCompanyDetail(companyId: string): Promise<CompanyDetail> {
    const { data, error: rpcError } = await (supabase as any)
      .rpc('get_platform_company_detail', { p_company_id: companyId })
    if (rpcError) throw rpcError
    return data as CompanyDetail
  }

  return { overview, isPlatformAdmin, loading, error, fetchOverview, checkIsPlatformAdmin, fetchCompanyDetail }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `cd management-frontend && npx vitest run app/composables/__tests__/usePlatformAdmin.test.ts`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/composables/usePlatformAdmin.ts management-frontend/app/composables/__tests__/usePlatformAdmin.test.ts
git commit -m "feat(platform-admin): usePlatformAdmin composable + pure helpers"
```

---

## Chunk 3: Frontend UI

### Task 4: Route-guard middleware

**Files:**
- Create: `management-frontend/app/middleware/platform-admin.ts`

Named middleware (like `auth.ts`); applied per-page via `definePageMeta`. Skips SSR (same reason as `auth.ts`: the Supabase URL is rewritten client-side only), then verifies platform-admin via the RPC and redirects non-admins to `/`.

- [ ] **Step 1: Write the middleware**

```ts
export default defineNuxtRouteMiddleware(async () => {
  // Client-only: the Supabase URL is rewritten in a .client plugin, so SSR
  // RPC calls would hit the wrong host (mirrors middleware/auth.ts).
  if (import.meta.server) return

  const { isPlatformAdmin, checkIsPlatformAdmin } = usePlatformAdmin()
  if (isPlatformAdmin.value) return

  const ok = await checkIsPlatformAdmin()
  if (!ok) return navigateTo('/')
})
```

- [ ] **Step 2: Commit**

```bash
git add management-frontend/app/middleware/platform-admin.ts
git commit -m "feat(platform-admin): route-guard middleware for /admin"
```

### Task 5: i18n strings (en + de)

**Files:**
- Modify: `management-frontend/i18n/locales/en.json`
- Modify: `management-frontend/i18n/locales/de.json`

- [ ] **Step 1: Add a `platformAdmin` block + the nav key to `en.json`**

Add a `"platformAdmin"` top-level object and a `"platform"` key inside the existing `"nav"` object:

```jsonc
// inside "nav": { ... }
"platform": "Platform",

// new top-level block
"platformAdmin": {
  "title": "Platform Overview",
  "subtitle": "Cross-company operator dashboard",
  "totals": {
    "companies": "Companies",
    "users": "Users",
    "machines": "Machines",
    "devices": "Devices",
    "devicesOnline": "Devices online"
  },
  "table": {
    "company": "Company",
    "users": "Users",
    "machines": "Machines",
    "devicesOnline": "Online / Total",
    "salesWindow": "Sales ({days}d)",
    "revenueWindow": "Revenue ({days}d)",
    "lastActivity": "Last activity",
    "activity": "Activity"
  },
  "activity": { "active": "Active", "idle": "Idle", "dead": "Inactive" },
  "detail": {
    "back": "Back to overview",
    "members": "Members",
    "devices": "Devices",
    "recentSales": "Recent sales",
    "role": "Role",
    "email": "Email",
    "joined": "Joined",
    "status": "Status",
    "lastSeen": "Last seen",
    "firmware": "Firmware",
    "machine": "Machine",
    "price": "Price",
    "channel": "Channel",
    "time": "Time",
    "noSales": "No sales yet",
    "online": "Online",
    "offline": "Offline"
  },
  "neverActive": "never"
}
```

- [ ] **Step 2: Add the matching German block to `de.json`** (du-tone, consistent with the app)

```jsonc
// inside "nav": { ... }
"platform": "Plattform",

"platformAdmin": {
  "title": "Plattform-Übersicht",
  "subtitle": "Firmenübergreifendes Betreiber-Dashboard",
  "totals": {
    "companies": "Firmen",
    "users": "Nutzer",
    "machines": "Automaten",
    "devices": "Geräte",
    "devicesOnline": "Geräte online"
  },
  "table": {
    "company": "Firma",
    "users": "Nutzer",
    "machines": "Automaten",
    "devicesOnline": "Online / Gesamt",
    "salesWindow": "Verkäufe ({days}T)",
    "revenueWindow": "Umsatz ({days}T)",
    "lastActivity": "Letzte Aktivität",
    "activity": "Aktivität"
  },
  "activity": { "active": "Aktiv", "idle": "Inaktiv", "dead": "Tot" },
  "detail": {
    "back": "Zurück zur Übersicht",
    "members": "Mitglieder",
    "devices": "Geräte",
    "recentSales": "Letzte Verkäufe",
    "role": "Rolle",
    "email": "E-Mail",
    "joined": "Beigetreten",
    "status": "Status",
    "lastSeen": "Zuletzt gesehen",
    "firmware": "Firmware",
    "machine": "Automat",
    "price": "Preis",
    "channel": "Kanal",
    "time": "Zeit",
    "noSales": "Noch keine Verkäufe",
    "online": "Online",
    "offline": "Offline"
  },
  "neverActive": "nie"
}
```

- [ ] **Step 3: Verify JSON is valid**

Run: `cd management-frontend && node -e "JSON.parse(require('fs').readFileSync('i18n/locales/en.json','utf8')); JSON.parse(require('fs').readFileSync('i18n/locales/de.json','utf8')); console.log('ok')"`
Expected: `ok`

- [ ] **Step 4: Commit**

```bash
git add management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "feat(platform-admin): en/de strings"
```

### Task 6: Overview page

**Files:**
- Create: `management-frontend/app/pages/admin/platform/index.vue`

Uses `definePageMeta({ middleware: ['auth', 'platform-admin'] })`, fetches the overview on mount, renders KPI cards + a sortable company table (reuse `useTableSort` and `formatCurrency`/`timeAgo` from `~/lib/utils`). Each row links to the detail page. Match the shadcn card/table styling used on existing pages (e.g. `pages/index.vue`, `pages/devices/index.vue`).

- [ ] **Step 1: Write the page**

```vue
<script setup lang="ts">
definePageMeta({ middleware: ['auth', 'platform-admin'] })

import { computed, onMounted } from 'vue'
import { useI18n } from 'vue-i18n'
import { usePlatformAdmin, companyActivityLevel } from '~/composables/usePlatformAdmin'
import { useTableSort } from '~/composables/useTableSort'
import { formatCurrency, timeAgo } from '~/lib/utils'

const { t } = useI18n()
const { overview, loading, error, fetchOverview } = usePlatformAdmin()

// useTableSort only tracks sort STATE ({ sortKey, sortDir, toggleSort, sortIcon });
// it does NOT sort data. The generic is the union of sortable column keys.
// Sorting is done in a local computed (same pattern as pages/devices/index.vue).
type SortKey = 'name' | 'user_count' | 'machine_count' | 'sales_window_count' | 'sales_window_revenue' | 'last_sale_at'
const { sortKey, sortDir, toggleSort } = useTableSort<SortKey>('sales_window_revenue', 'desc')

const sortedCompanies = computed(() => {
  const rows = overview.value?.companies ?? []
  const dir = sortDir.value === 'asc' ? 1 : -1
  return [...rows].sort((a, b) => {
    const k = sortKey.value
    if (k === 'name') return dir * (a.name ?? '').localeCompare(b.name ?? '')
    if (k === 'last_sale_at') return dir * (a.last_sale_at ?? '').localeCompare(b.last_sale_at ?? '')
    return dir * (((a[k] as number) ?? 0) - ((b[k] as number) ?? 0))
  })
})

const days = 30
onMounted(() => { fetchOverview(days).catch(() => {}) })

const activityClass: Record<string, string> = {
  active: 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400',
  idle: 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400',
  dead: 'bg-muted text-muted-foreground',
}
</script>

<template>
  <div class="p-4 space-y-6">
    <div>
      <h1 class="text-2xl font-semibold">{{ t('platformAdmin.title') }}</h1>
      <p class="text-muted-foreground">{{ t('platformAdmin.subtitle') }}</p>
    </div>

    <p v-if="error" class="text-destructive">{{ error }}</p>
    <p v-if="loading" class="text-muted-foreground">…</p>

    <div v-if="overview" class="grid grid-cols-2 md:grid-cols-5 gap-3">
      <div v-for="card in [
        { label: t('platformAdmin.totals.companies'), value: overview.totals.company_count },
        { label: t('platformAdmin.totals.users'), value: overview.totals.user_count },
        { label: t('platformAdmin.totals.machines'), value: overview.totals.machine_count },
        { label: t('platformAdmin.totals.devices'), value: overview.totals.device_count },
        { label: t('platformAdmin.totals.devicesOnline'), value: overview.totals.devices_online },
      ]" :key="card.label" class="rounded-lg border p-4">
        <div class="text-sm text-muted-foreground">{{ card.label }}</div>
        <div class="text-2xl font-semibold tabular-nums">{{ card.value }}</div>
      </div>
    </div>

    <div v-if="overview" class="rounded-lg border overflow-x-auto">
      <table class="w-full text-sm">
        <thead class="bg-muted/50">
          <tr class="text-left">
            <th class="p-2 cursor-pointer" @click="toggleSort('name')">{{ t('platformAdmin.table.company') }}</th>
            <th class="p-2 cursor-pointer" @click="toggleSort('user_count')">{{ t('platformAdmin.table.users') }}</th>
            <th class="p-2 cursor-pointer" @click="toggleSort('machine_count')">{{ t('platformAdmin.table.machines') }}</th>
            <th class="p-2">{{ t('platformAdmin.table.devicesOnline') }}</th>
            <th class="p-2 cursor-pointer" @click="toggleSort('sales_window_count')">{{ t('platformAdmin.table.salesWindow', { days }) }}</th>
            <th class="p-2 cursor-pointer" @click="toggleSort('sales_window_revenue')">{{ t('platformAdmin.table.revenueWindow', { days }) }}</th>
            <th class="p-2 cursor-pointer" @click="toggleSort('last_sale_at')">{{ t('platformAdmin.table.lastActivity') }}</th>
            <th class="p-2">{{ t('platformAdmin.table.activity') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="c in sortedCompanies"
            :key="c.company_id"
            class="border-t hover:bg-muted/40 cursor-pointer"
            @click="navigateTo(`/admin/platform/${c.company_id}`)"
          >
            <td class="p-2 font-medium">{{ c.name }}</td>
            <td class="p-2 tabular-nums">{{ c.user_count }}</td>
            <td class="p-2 tabular-nums">{{ c.machine_count }}</td>
            <td class="p-2 tabular-nums">{{ c.devices_online }} / {{ c.device_count }}</td>
            <td class="p-2 tabular-nums">{{ c.sales_window_count }}</td>
            <td class="p-2 tabular-nums">{{ formatCurrency(c.sales_window_revenue) }}</td>
            <td class="p-2">{{ c.last_sale_at ? timeAgo(c.last_sale_at, t) : t('platformAdmin.neverActive') }}</td>
            <td class="p-2">
              <span class="rounded px-2 py-0.5 text-xs" :class="activityClass[companyActivityLevel(c.last_sale_at)]">
                {{ t(`platformAdmin.activity.${companyActivityLevel(c.last_sale_at)}`) }}
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
```

> `useTableSort<K extends string>(defaultKey, defaultDir)` returns `{ sortKey, sortDir, toggleSort, sortIcon }` and tracks **state only** — it does not sort the array (verified `management-frontend/app/composables/useTableSort.ts`; same usage as `pages/devices/index.vue:19-37`). The local `sortedCompanies` computed above does the actual sorting.

- [ ] **Step 2: Commit**

```bash
git add management-frontend/app/pages/admin/platform/index.vue
git commit -m "feat(platform-admin): overview page (KPIs + company table)"
```

### Task 7: Drill-down page

**Files:**
- Create: `management-frontend/app/pages/admin/platform/[companyId].vue`

- [ ] **Step 1: Write the page**

```vue
<script setup lang="ts">
definePageMeta({ middleware: ['auth', 'platform-admin'] })

import { ref, onMounted } from 'vue'
import { useRoute } from 'vue-router'
import { useI18n } from 'vue-i18n'
import { usePlatformAdmin, isDeviceOnline, type CompanyDetail } from '~/composables/usePlatformAdmin'
import { formatCurrency, timeAgo, formatDateTime } from '~/lib/utils'

const { t } = useI18n()
const route = useRoute()
const { fetchCompanyDetail } = usePlatformAdmin()

const detail = ref<CompanyDetail | null>(null)
const loading = ref(true)
const error = ref('')

onMounted(async () => {
  try {
    detail.value = await fetchCompanyDetail(route.params.companyId as string)
  } catch (err: any) {
    error.value = err?.message ?? 'failed to load company detail'
  } finally {
    loading.value = false
  }
})
</script>

<template>
  <div class="p-4 space-y-6">
    <NuxtLink to="/admin/platform" class="text-sm text-muted-foreground hover:underline">
      ← {{ t('platformAdmin.detail.back') }}
    </NuxtLink>

    <p v-if="error" class="text-destructive">{{ error }}</p>
    <p v-if="loading" class="text-muted-foreground">…</p>

    <template v-if="detail">
      <h1 class="text-2xl font-semibold">{{ detail.company?.name }}</h1>

      <!-- Members -->
      <section class="space-y-2">
        <h2 class="font-semibold">{{ t('platformAdmin.detail.members') }}</h2>
        <div class="rounded-lg border overflow-x-auto">
          <table class="w-full text-sm">
            <thead class="bg-muted/50 text-left">
              <tr>
                <th class="p-2">{{ t('platformAdmin.detail.email') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.role') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.joined') }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="m in detail.members" :key="m.user_id" class="border-t">
                <td class="p-2">{{ m.email }}</td>
                <td class="p-2">{{ m.role }}</td>
                <td class="p-2">{{ timeAgo(m.joined_at, t) }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <!-- Devices -->
      <section class="space-y-2">
        <h2 class="font-semibold">{{ t('platformAdmin.detail.devices') }}</h2>
        <div class="rounded-lg border overflow-x-auto">
          <table class="w-full text-sm">
            <thead class="bg-muted/50 text-left">
              <tr>
                <th class="p-2">{{ t('platformAdmin.detail.machine') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.status') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.lastSeen') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.firmware') }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="d in detail.devices" :key="d.embedded_id" class="border-t">
                <td class="p-2">{{ d.machine_name ?? ('#' + d.subdomain) }}</td>
                <td class="p-2">
                  <span :class="isDeviceOnline(d.status) ? 'text-green-600' : 'text-muted-foreground'">
                    {{ isDeviceOnline(d.status) ? t('platformAdmin.detail.online') : t('platformAdmin.detail.offline') }}
                  </span>
                </td>
                <td class="p-2">{{ d.status_at ? timeAgo(d.status_at, t) : '—' }}</td>
                <td class="p-2">{{ d.firmware_version ?? '—' }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <!-- Recent sales -->
      <section class="space-y-2">
        <h2 class="font-semibold">{{ t('platformAdmin.detail.recentSales') }}</h2>
        <p v-if="detail.recent_sales.length === 0" class="text-muted-foreground text-sm">
          {{ t('platformAdmin.detail.noSales') }}
        </p>
        <div v-else class="rounded-lg border overflow-x-auto">
          <table class="w-full text-sm">
            <thead class="bg-muted/50 text-left">
              <tr>
                <th class="p-2">{{ t('platformAdmin.detail.time') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.machine') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.price') }}</th>
                <th class="p-2">{{ t('platformAdmin.detail.channel') }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="(s, i) in detail.recent_sales" :key="i" class="border-t">
                <td class="p-2">{{ formatDateTime(s.created_at) }}</td>
                <td class="p-2">{{ s.machine_name ?? '—' }}</td>
                <td class="p-2 tabular-nums">{{ formatCurrency(s.item_price) }}</td>
                <td class="p-2">{{ s.channel ?? '—' }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </template>
  </div>
</template>
```

> Confirm `formatDateTime` is exported from `~/lib/utils` (CLAUDE.md lists it). If not present, use `formatDate`/`formatTime` or add it.

- [ ] **Step 2: Commit**

```bash
git add management-frontend/app/pages/admin/platform/[companyId].vue
git commit -m "feat(platform-admin): per-company drill-down page"
```

### Task 8: Sidebar nav entry (platform-admins only)

**Files:**
- Modify: `management-frontend/app/components/AppSidebar.vue`

Add a "Plattform" nav entry shown only when the current user is a platform admin — mirroring the existing `if (role.value === 'admin')` block (`AppSidebar.vue:115-136`). Resolve admin status via the composable on mount.

- [ ] **Step 1: Wire the platform-admin check into the sidebar**

In `<script setup>`, alongside the existing `const { organization, role } = useOrganization()`:

```ts
import { onMounted } from 'vue'
const { isPlatformAdmin, checkIsPlatformAdmin } = usePlatformAdmin()
onMounted(() => { checkIsPlatformAdmin().catch(() => {}) })
```

Pick an icon already imported in the file (e.g. reuse `IconUsers`) or add one to the existing `@tabler/icons-vue` import (e.g. `IconBuildingSkyscraper`). In the `navGroups` computed, append after the existing `role.value === 'admin'` block:

```ts
  if (isPlatformAdmin.value) {
    groups.push({
      label: t('nav.platform'),
      items: [
        {
          title: t('nav.platform'),
          url: "/admin/platform",
          icon: IconBuildingSkyscraper, // or an already-imported icon
        },
      ],
    })
  }
```

> `navGroups` is a `computed` that reads `isPlatformAdmin` (a `useState` ref), so it re-evaluates automatically once `checkIsPlatformAdmin()` resolves. Verify the icon name resolves against the file's existing `@tabler/icons-vue` import; add it to that import if missing.

- [ ] **Step 2: Verify the build/typecheck and full test suite**

Run: `cd management-frontend && npx vitest run`
Expected: PASS, including the new `usePlatformAdmin.test.ts`.

Run: `cd management-frontend && npm run build`
Expected: build completes with no errors (catches template/type mistakes in the new pages).

- [ ] **Step 3: Commit**

```bash
git add management-frontend/app/components/AppSidebar.vue
git commit -m "feat(platform-admin): conditional sidebar entry"
```

---

## Final Verification (manual, after all tasks)

- [ ] `cd Docker/supabase && ./tests/run-sql-tests.sh` → platform tests pass.
- [ ] `cd management-frontend && npx vitest run` → all green.
- [ ] `cd management-frontend && npm run build` → succeeds.
- [ ] Manual smoke (dev): log in as `lucien@kerl-handel.de`, confirm the "Plattform" sidebar entry appears, `/admin/platform` shows totals + company table, a row opens the drill-down, and a **non-platform-admin** account is redirected away from `/admin/platform` and sees no nav entry. (Use the `@verify` skill / preview tools.)

## Notes / Guardrails carried from the spec
- **Read-only only** — no destructive actions this iteration.
- **No `/api/v1` exposure** — cross-company stats must not be reachable via tenant API keys.
- **Backward-compatible** — purely additive; no existing RLS/table/firmware/MQTT touched.
- **LAN/VPN** restriction of `/admin/**` is an optional reverse-proxy ops step (defense-in-depth), not code in this plan.
- **`item_price` is EUR** — never divide by 100.

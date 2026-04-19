-- =========================================================
-- Offline sales protection
--
-- Adds the infrastructure the firmware + backend need to guarantee that no
-- sale is ever lost due to a temporary outage of the device, the MQTT broker,
-- the forwarder, or Supabase itself:
--
--   1. `sales.sale_seq` (nullable bigint) + UNIQUE(embedded_id, sale_seq):
--      device-side monotonic counter stored in NVS. Safe replay at any layer
--      (device queue drain, broker retention, forwarder DLQ) cannot produce
--      duplicate rows — ON CONFLICT DO NOTHING in the webhook is a no-op
--      on the second attempt, and the BEFORE INSERT trigger that decrements
--      machine_trays.current_stock never fires a second time.
--
--   2. `sales.time_uncertain` (boolean, default false): set to true when the
--      device's clock had not synchronised with SNTP at the moment the vend
--      occurred. In that case the webhook substitutes the server receive time
--      for `created_at`, so the sale is always recorded (±window drift is
--      acceptable in exchange for guaranteed persistence).
--
--   3. `dex_snapshots` table: cumulative DEX audit counters. A nightly
--      reconciliation job can compare delta(cumulative) against count(sales)
--      per device/slot to detect and back-fill any sales that escaped every
--      other persistence layer (belt-and-suspenders against firmware bugs /
--      flash corruption).
--
-- All changes are idempotent (IF NOT EXISTS / CREATE OR REPLACE) so re-runs
-- on partially-applied databases are safe.
-- =========================================================

-- 1. sales.sale_seq + UNIQUE ---------------------------------------------
alter table public.sales
  add column if not exists sale_seq bigint;

create unique index if not exists sales_embedded_seq_unique
  on public.sales (embedded_id, sale_seq)
  where sale_seq is not null;

comment on column public.sales.sale_seq is
  'Device-side monotonic sale counter. Combined with embedded_id this uniquely identifies a vend event for idempotent replay.';

-- 2. sales.time_uncertain -------------------------------------------------
alter table public.sales
  add column if not exists time_uncertain boolean not null default false;

comment on column public.sales.time_uncertain is
  'True when the device had no synchronised clock at vend time. created_at is the server receive time in that case, not the original vend timestamp.';

-- 3. DEX snapshots --------------------------------------------------------
create table if not exists public.dex_snapshots (
  id              uuid not null default gen_random_uuid(),
  embedded_id     uuid not null references public.embeddeds(id) on delete cascade,
  captured_at     timestamp with time zone not null default now(),
  -- Raw DEX bytes (base64 not needed — bytea is native). Kept so we can
  -- re-parse historical snapshots when the parser improves.
  raw             bytea,
  -- Per-slot cumulative counters extracted from PA1/PA2 records.
  -- {"1": {"vends": 123, "value_cents": 15000}, "2": {...}}
  slot_counters   jsonb not null default '{}'::jsonb,
  -- Summary fields lifted out for fast querying / reconciliation.
  total_vends     bigint,
  total_value     numeric(14,4),
  constraint dex_snapshots_pkey primary key (id)
);

create index if not exists dex_snapshots_embedded_captured_idx
  on public.dex_snapshots (embedded_id, captured_at desc);

alter table public.dex_snapshots enable row level security;

grant select on public.dex_snapshots to authenticated;
grant select, insert, update, delete on public.dex_snapshots to service_role;

-- Tenants can view DEX snapshots for their own devices
drop policy if exists dex_snapshots_select_own on public.dex_snapshots;
create policy dex_snapshots_select_own on public.dex_snapshots
  for select to authenticated
  using (
    exists (
      select 1 from public.embeddeds e
      where e.id = dex_snapshots.embedded_id
        and e.company = public.my_company_id()
    )
  );

comment on table public.dex_snapshots is
  'DEX/DDCMP audit snapshots from vending machines, used to reconcile sales against the machine''s internal counters.';

-- 4. Reconciliation helper ------------------------------------------------
-- Returns slots where cumulative DEX vend counters grew by more than the
-- number of `sales` rows in the same window. Operators can review these
-- gaps and, if warranted, insert compensating rows with source='dex_reconcile'.
create or replace function public.dex_reconcile_gaps(
  p_embedded_id uuid,
  p_window_start timestamptz,
  p_window_end timestamptz
)
returns table (
  item_number integer,
  dex_delta   bigint,
  sales_count bigint,
  gap         bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  with start_snap as (
    select slot_counters
    from public.dex_snapshots
    where embedded_id = p_embedded_id
      and captured_at <= p_window_start
    order by captured_at desc
    limit 1
  ),
  end_snap as (
    select slot_counters
    from public.dex_snapshots
    where embedded_id = p_embedded_id
      and captured_at <= p_window_end
    order by captured_at desc
    limit 1
  ),
  slot_deltas as (
    select
      (key)::integer as item_number,
      coalesce(((end_snap.slot_counters -> key) ->> 'vends')::bigint, 0)
        - coalesce(((start_snap.slot_counters -> key) ->> 'vends')::bigint, 0) as dex_delta
    from end_snap
    cross join start_snap
    cross join jsonb_object_keys(end_snap.slot_counters) as key
  ),
  sales_counts as (
    select s.item_number, count(*)::bigint as sales_count
    from public.sales s
    where s.embedded_id = p_embedded_id
      and s.created_at >= p_window_start
      and s.created_at <  p_window_end
    group by s.item_number
  )
  select
    d.item_number,
    d.dex_delta,
    coalesce(c.sales_count, 0) as sales_count,
    greatest(0, d.dex_delta - coalesce(c.sales_count, 0)) as gap
  from slot_deltas d
  left join sales_counts c using (item_number)
  where d.dex_delta > 0
$$;

comment on function public.dex_reconcile_gaps(uuid, timestamptz, timestamptz) is
  'Returns per-slot gaps between DEX cumulative vend counters and recorded sales in a time window. Positive gap = suspected lost sales.';

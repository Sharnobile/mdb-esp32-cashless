-- Enhanced AI Insights: cache table + v2 RPC with warehouse stock, trends, no current_stock

-- ── Cache table ────────────────────────────────────────────────────────────────

create table if not exists public.machine_insights_cache (
  id          uuid primary key default gen_random_uuid(),
  machine_id  uuid not null references public."vendingMachine"(id) on delete cascade,
  company_id  uuid not null references public.companies(id) on delete cascade,
  period_days int not null,
  response    jsonb not null,
  created_at  timestamptz not null default now(),
  unique (machine_id, period_days)
);

alter table public.machine_insights_cache enable row level security;

-- Only service_role can access cache (edge function uses service role client)
create policy "service_role_all" on public.machine_insights_cache
  for all to service_role using (true) with check (true);

-- ── V2 RPC: enhanced KPIs ──────────────────────────────────────────────────────
-- Keeps v1 intact for backward compatibility.
-- Changes vs v1:
--   - Removes current_stock + days_until_empty from tray output
--   - Adds warehouse_stock section (available qty from non-expired batches)
--   - Adds trends section (current vs previous period comparison)

create or replace function get_machine_insights_kpis_v2(
  p_machine_id  uuid,
  p_company_id  uuid,
  p_days        int default 30
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_window_start     timestamptz;
  v_prev_window_start timestamptz;
  v_machine_name     text;
  v_machine_status   text;
  v_machine_exists   boolean;
  v_total_units      bigint;
  v_total_revenue    numeric;
  v_prev_units       bigint;
  v_prev_revenue     numeric;
  v_pax_count        bigint;
  v_conversion       numeric;
  v_trays_json       json;
  v_refills_json     json;
  v_warehouse_json   json;
  v_summary_json     json;
  v_pax_json         json;
  v_trends_json      json;
begin
  -- Time windows
  v_window_start := now() - (p_days || ' days')::interval;
  v_prev_window_start := v_window_start - (p_days || ' days')::interval;

  -- Validate company ownership
  select
    vm.name,
    e.status,
    true
  into
    v_machine_name,
    v_machine_status,
    v_machine_exists
  from public."vendingMachine" vm
  left join public.embeddeds e on e.id = vm.embedded
  where vm.id = p_machine_id
    and vm.company = p_company_id;

  if not found then
    return null;
  end if;

  -- ── Current period totals ──────────────────────────────────────────────────
  select
    coalesce(count(*), 0),
    coalesce(sum(item_price), 0)
  into
    v_total_units,
    v_total_revenue
  from public.sales
  where machine_id  = p_machine_id
    and created_at >= v_window_start;

  -- ── Previous period totals (for trend comparison) ──────────────────────────
  select
    coalesce(count(*), 0),
    coalesce(sum(item_price), 0)
  into
    v_prev_units,
    v_prev_revenue
  from public.sales
  where machine_id   = p_machine_id
    and created_at  >= v_prev_window_start
    and created_at  <  v_window_start;

  -- ── Per-tray KPIs (without current_stock / days_until_empty) ───────────────
  select json_agg(tray_row order by tray_row.item_number)
  into v_trays_json
  from (
    select
      mt.item_number,
      coalesce(p.name, 'Empty Slot')                                    as product_name,
      mt.product_id,
      mt.capacity,
      count(s.id)                                                         as units_sold,
      round(coalesce(sum(s.item_price), 0)::numeric, 2)                   as revenue_eur,
      round(
        case
          when mt.capacity > 0 and p_days > 0
          then least(count(s.id)::numeric / (mt.capacity::numeric * p_days / 7) * 100, 100)
          else 0::numeric
        end,
        1
      )                                                                   as sell_through_pct,
      round(count(s.id)::numeric / p_days, 2)                            as avg_daily_units,
      (count(s.id) = 0 and mt.capacity > 0)                             as is_dead_stock
    from public.machine_trays mt
    left join public.products p on p.id = mt.product_id
    left join public.sales s
      on  s.machine_id  = p_machine_id
      and s.item_number = mt.item_number
      and s.created_at >= v_window_start
    where mt.machine_id = p_machine_id
    group by mt.item_number, p.name, mt.product_id, mt.capacity
  ) as tray_row;

  -- ── Paxcounter ─────────────────────────────────────────────────────────────
  select coalesce(count, 0)
  into v_pax_count
  from public.paxcounter
  where machine_id = p_machine_id
  order by created_at desc
  limit 1;

  if v_pax_count > 0 then
    v_conversion := round(v_total_units::numeric / v_pax_count, 4);
  else
    v_conversion := null;
  end if;

  v_pax_json := json_build_object(
    'latest_count',    v_pax_count,
    'conversion_rate', v_conversion
  );

  -- ── Refill history (last 10 outgoing_refill events) ────────────────────────
  select json_agg(r order by r.refill_date desc)
  into v_refills_json
  from (
    select
      date(wt.created_at)          as refill_date,
      coalesce(p.name, 'Unknown')  as product_name,
      abs(wt.quantity_change)      as quantity
    from public.warehouse_transactions wt
    left join public.products p on p.id = wt.product_id
    where wt.transaction_type = 'outgoing_refill'
      and wt.reference_id    = p_machine_id::text
    order by wt.created_at desc
    limit 10
  ) r;

  -- ── Warehouse stock for products in this machine's trays ───────────────────
  select json_agg(ws order by ws.product_name)
  into v_warehouse_json
  from (
    select
      p.name                        as product_name,
      w.name                        as warehouse_name,
      coalesce(sum(wsb.quantity), 0) as available_qty
    from public.machine_trays mt
    join public.products p on p.id = mt.product_id
    join public.warehouse_stock_batches wsb on wsb.product_id = p.id
    join public.warehouses w on w.id = wsb.warehouse_id
    where mt.machine_id = p_machine_id
      and wsb.quantity > 0
      and (wsb.expiration_date is null or wsb.expiration_date > now())
    group by p.name, w.name
  ) ws;

  -- ── Trends: current vs previous period ─────────────────────────────────────
  v_trends_json := json_build_object(
    'current_revenue_eur',  round(v_total_revenue::numeric, 2),
    'current_total_units',  v_total_units,
    'prev_revenue_eur',     round(v_prev_revenue::numeric, 2),
    'prev_total_units',     v_prev_units,
    'revenue_change_pct',   case
                              when v_prev_revenue > 0
                              then round(((v_total_revenue - v_prev_revenue)::numeric / v_prev_revenue) * 100, 1)
                              else null
                            end,
    'units_change_pct',     case
                              when v_prev_units > 0
                              then round(((v_total_units - v_prev_units)::numeric / v_prev_units) * 100, 1)
                              else null
                            end
  );

  -- ── Summary ────────────────────────────────────────────────────────────────
  v_summary_json := json_build_object(
    'total_revenue_eur',      round(v_total_revenue::numeric, 2),
    'total_units',            v_total_units,
    'avg_daily_revenue_eur',  round(v_total_revenue::numeric / p_days, 2)
  );

  -- ── Assemble and return ────────────────────────────────────────────────────
  return json_build_object(
    'machine',         json_build_object(
                         'id',     p_machine_id,
                         'name',   v_machine_name,
                         'status', v_machine_status
                       ),
    'period_days',     p_days,
    'summary',         v_summary_json,
    'trays',           coalesce(v_trays_json, '[]'::json),
    'paxcounter',      v_pax_json,
    'refill_history',  coalesce(v_refills_json, '[]'::json),
    'warehouse_stock', coalesce(v_warehouse_json, '[]'::json),
    'trends',          v_trends_json
  );
end;
$$;

grant execute on function get_machine_insights_kpis_v2(uuid, uuid, int) to authenticated;
grant execute on function get_machine_insights_kpis_v2(uuid, uuid, int) to service_role;

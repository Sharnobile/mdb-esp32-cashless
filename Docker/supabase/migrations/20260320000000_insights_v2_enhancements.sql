-- Enhanced AI Insights v1.5: history table, cache locale, DOW/hourly in V2 RPC, company-wide RPC

-- ── A. History table (append-only, permanent) ──────────────────────────────────

create table if not exists public.machine_insights_history (
  id               uuid primary key default gen_random_uuid(),
  machine_id       uuid references public."vendingMachine"(id) on delete cascade,
  company_id       uuid not null references public.companies(id) on delete cascade,
  period_days      int not null,
  locale           text not null default 'en',
  recommendations  jsonb,
  summary          text,
  trends           jsonb,
  generated_at     timestamptz not null,
  created_at       timestamptz not null default now()
);

create index if not exists idx_mih_machine_created
  on public.machine_insights_history (machine_id, created_at desc);
create index if not exists idx_mih_company_created
  on public.machine_insights_history (company_id, created_at desc);

alter table public.machine_insights_history enable row level security;

create policy "service_role_all" on public.machine_insights_history
  for all to service_role using (true) with check (true);

-- Cleanup trigger: keep last 20 per scope (machine_id or company-wide)
create or replace function public.cleanup_insights_history()
returns trigger
language plpgsql
as $$
begin
  if NEW.machine_id is not null then
    delete from public.machine_insights_history
    where machine_id = NEW.machine_id
      and id not in (
        select id from public.machine_insights_history
        where machine_id = NEW.machine_id
        order by created_at desc
        limit 20
      );
  else
    delete from public.machine_insights_history
    where company_id = NEW.company_id
      and machine_id is null
      and id not in (
        select id from public.machine_insights_history
        where company_id = NEW.company_id
          and machine_id is null
        order by created_at desc
        limit 20
      );
  end if;
  return NEW;
end;
$$;

create trigger trg_cleanup_insights_history
  after insert on public.machine_insights_history
  for each row execute function public.cleanup_insights_history();

-- ── B. Cache table: add locale column + update unique constraint ───────────────

alter table public.machine_insights_cache
  add column if not exists locale text not null default 'en';

alter table public.machine_insights_cache
  drop constraint if exists machine_insights_cache_machine_id_period_days_key;

alter table public.machine_insights_cache
  add constraint machine_insights_cache_machine_period_locale_key
  unique (machine_id, period_days, locale);

-- ── C. Update get_machine_insights_kpis_v2: add DOW + hourly distributions ─────

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
  v_window_start      timestamptz;
  v_prev_window_start timestamptz;
  v_machine_name      text;
  v_machine_status    text;
  v_machine_exists    boolean;
  v_total_units       bigint;
  v_total_revenue     numeric;
  v_prev_units        bigint;
  v_prev_revenue      numeric;
  v_pax_count         bigint;
  v_conversion        numeric;
  v_trays_json        json;
  v_refills_json      json;
  v_warehouse_json    json;
  v_summary_json      json;
  v_pax_json          json;
  v_trends_json       json;
  v_dow_json          json;
  v_hourly_json       json;
  v_peak_json         json;
begin
  v_window_start := now() - (p_days || ' days')::interval;
  v_prev_window_start := v_window_start - (p_days || ' days')::interval;

  -- Validate company ownership
  select vm.name, e.status, true
  into v_machine_name, v_machine_status, v_machine_exists
  from public."vendingMachine" vm
  left join public.embeddeds e on e.id = vm.embedded
  where vm.id = p_machine_id and vm.company = p_company_id;

  if not found then return null; end if;

  -- Current period totals
  select coalesce(count(*), 0), coalesce(sum(item_price), 0)
  into v_total_units, v_total_revenue
  from public.sales
  where machine_id = p_machine_id and created_at >= v_window_start;

  -- Previous period totals
  select coalesce(count(*), 0), coalesce(sum(item_price), 0)
  into v_prev_units, v_prev_revenue
  from public.sales
  where machine_id = p_machine_id
    and created_at >= v_prev_window_start
    and created_at < v_window_start;

  -- Per-tray KPIs
  select json_agg(tray_row order by tray_row.item_number)
  into v_trays_json
  from (
    select
      mt.item_number,
      coalesce(p.name, 'Empty Slot') as product_name,
      mt.product_id,
      mt.capacity,
      count(s.id) as units_sold,
      round(coalesce(sum(s.item_price), 0)::numeric, 2) as revenue_eur,
      round(
        case when mt.capacity > 0 and p_days > 0
          then least(count(s.id)::numeric / (mt.capacity::numeric * p_days / 7) * 100, 100)
          else 0::numeric end, 1
      ) as sell_through_pct,
      round(count(s.id)::numeric / p_days, 2) as avg_daily_units,
      (count(s.id) = 0 and mt.capacity > 0) as is_dead_stock
    from public.machine_trays mt
    left join public.products p on p.id = mt.product_id
    left join public.sales s
      on s.machine_id = p_machine_id
      and s.item_number = mt.item_number
      and s.created_at >= v_window_start
    where mt.machine_id = p_machine_id
    group by mt.item_number, p.name, mt.product_id, mt.capacity
  ) as tray_row;

  -- Paxcounter
  select coalesce(count, 0) into v_pax_count
  from public.paxcounter
  where machine_id = p_machine_id
  order by created_at desc limit 1;

  if v_pax_count > 0 then
    v_conversion := round(v_total_units::numeric / v_pax_count, 4);
  else
    v_conversion := null;
  end if;

  v_pax_json := json_build_object('latest_count', v_pax_count, 'conversion_rate', v_conversion);

  -- Refill history (last 10)
  select json_agg(r order by r.refill_date desc)
  into v_refills_json
  from (
    select date(wt.created_at) as refill_date,
      coalesce(p.name, 'Unknown') as product_name,
      abs(wt.quantity_change) as quantity
    from public.warehouse_transactions wt
    left join public.products p on p.id = wt.product_id
    where wt.transaction_type = 'outgoing_refill'
      and wt.reference_id = p_machine_id::text
    order by wt.created_at desc limit 10
  ) r;

  -- Warehouse stock
  select json_agg(ws order by ws.product_name)
  into v_warehouse_json
  from (
    select p.name as product_name, w.name as warehouse_name,
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

  -- Day-of-week distribution
  select json_agg(d order by d.dow)
  into v_dow_json
  from (
    select
      extract(dow from created_at)::int as dow,
      case extract(dow from created_at)::int
        when 0 then 'Sun' when 1 then 'Mon' when 2 then 'Tue'
        when 3 then 'Wed' when 4 then 'Thu' when 5 then 'Fri'
        when 6 then 'Sat' end as day_name,
      count(*)::int as total_sales,
      round(coalesce(sum(item_price), 0)::numeric, 2) as revenue_eur
    from public.sales
    where machine_id = p_machine_id and created_at >= v_window_start
    group by extract(dow from created_at)::int
  ) d;

  -- Hourly distribution
  select json_agg(h order by h.hour)
  into v_hourly_json
  from (
    select
      extract(hour from created_at)::int as hour,
      count(*)::int as total_sales,
      round(coalesce(sum(item_price), 0)::numeric, 2) as revenue_eur
    from public.sales
    where machine_id = p_machine_id and created_at >= v_window_start
    group by extract(hour from created_at)::int
  ) h;

  -- Peak hours (top 3)
  select json_agg(ph order by ph.total_sales desc)
  into v_peak_json
  from (
    select
      extract(hour from created_at)::int as hour,
      count(*)::int as total_sales,
      round(count(*)::numeric / nullif(v_total_units, 0) * 100, 1) as pct_of_total
    from public.sales
    where machine_id = p_machine_id and created_at >= v_window_start
    group by extract(hour from created_at)::int
    order by count(*) desc
    limit 3
  ) ph;

  -- Trends
  v_trends_json := json_build_object(
    'current_revenue_eur', round(v_total_revenue::numeric, 2),
    'current_total_units', v_total_units,
    'prev_revenue_eur', round(v_prev_revenue::numeric, 2),
    'prev_total_units', v_prev_units,
    'revenue_change_pct', case when v_prev_revenue > 0
      then round(((v_total_revenue - v_prev_revenue)::numeric / v_prev_revenue) * 100, 1) else null end,
    'units_change_pct', case when v_prev_units > 0
      then round(((v_total_units - v_prev_units)::numeric / v_prev_units) * 100, 1) else null end
  );

  -- Summary
  v_summary_json := json_build_object(
    'total_revenue_eur', round(v_total_revenue::numeric, 2),
    'total_units', v_total_units,
    'avg_daily_revenue_eur', round(v_total_revenue::numeric / p_days, 2)
  );

  return json_build_object(
    'machine', json_build_object('id', p_machine_id, 'name', v_machine_name, 'status', v_machine_status),
    'period_days', p_days,
    'summary', v_summary_json,
    'trays', coalesce(v_trays_json, '[]'::json),
    'paxcounter', v_pax_json,
    'refill_history', coalesce(v_refills_json, '[]'::json),
    'warehouse_stock', coalesce(v_warehouse_json, '[]'::json),
    'trends', v_trends_json,
    'day_of_week_distribution', coalesce(v_dow_json, '[]'::json),
    'hourly_distribution', coalesce(v_hourly_json, '[]'::json),
    'peak_hours', coalesce(v_peak_json, '[]'::json)
  );
end;
$$;

grant execute on function get_machine_insights_kpis_v2(uuid, uuid, int) to authenticated;
grant execute on function get_machine_insights_kpis_v2(uuid, uuid, int) to service_role;

-- ── D. Company-wide insights RPC ───────────────────────────────────────────────

create or replace function get_company_insights_kpis(
  p_company_id  uuid,
  p_days        int default 30
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_window_start      timestamptz;
  v_prev_window_start timestamptz;
  v_company_name      text;
  v_total_units       bigint;
  v_total_revenue     numeric;
  v_prev_units        bigint;
  v_prev_revenue      numeric;
  v_machine_count     int;
  v_machines_json     json;
  v_top_json          json;
  v_bottom_json       json;
  v_dow_json          json;
  v_hourly_json       json;
  v_trends_json       json;
begin
  v_window_start := now() - (p_days || ' days')::interval;
  v_prev_window_start := v_window_start - (p_days || ' days')::interval;

  -- Validate company exists
  select name into v_company_name from public.companies where id = p_company_id;
  if not found then return null; end if;

  -- Machine count
  select count(*)::int into v_machine_count
  from public."vendingMachine" where company = p_company_id;

  -- Current period totals (all machines)
  select coalesce(count(*), 0), coalesce(sum(s.item_price), 0)
  into v_total_units, v_total_revenue
  from public.sales s
  join public."vendingMachine" vm on vm.id = s.machine_id
  where vm.company = p_company_id and s.created_at >= v_window_start;

  -- Previous period totals
  select coalesce(count(*), 0), coalesce(sum(s.item_price), 0)
  into v_prev_units, v_prev_revenue
  from public.sales s
  join public."vendingMachine" vm on vm.id = s.machine_id
  where vm.company = p_company_id
    and s.created_at >= v_prev_window_start
    and s.created_at < v_window_start;

  -- Per-machine summary (cap 50)
  select json_agg(m order by m.revenue_eur desc)
  into v_machines_json
  from (
    select
      vm.id,
      vm.name,
      coalesce(e.status, 'unknown') as status,
      count(s.id)::int as units,
      round(coalesce(sum(s.item_price), 0)::numeric, 2) as revenue_eur
    from public."vendingMachine" vm
    left join public.embeddeds e on e.id = vm.embedded
    left join public.sales s
      on s.machine_id = vm.id and s.created_at >= v_window_start
    where vm.company = p_company_id
    group by vm.id, vm.name, e.status
    order by revenue_eur desc
    limit 50
  ) m;

  -- Top 3 machines
  select json_agg(t) into v_top_json
  from (
    select * from json_array_elements(v_machines_json) as t
    limit 3
  ) t;

  -- Bottom 3 machines (with sales > 0)
  select json_agg(b) into v_bottom_json
  from (
    select * from json_array_elements(v_machines_json) as elem
    where (elem->>'units')::int > 0
    order by (elem->>'revenue_eur')::numeric asc
    limit 3
  ) b;

  -- Company-wide DOW distribution
  select json_agg(d order by d.dow)
  into v_dow_json
  from (
    select
      extract(dow from s.created_at)::int as dow,
      case extract(dow from s.created_at)::int
        when 0 then 'Sun' when 1 then 'Mon' when 2 then 'Tue'
        when 3 then 'Wed' when 4 then 'Thu' when 5 then 'Fri'
        when 6 then 'Sat' end as day_name,
      count(*)::int as total_sales,
      round(coalesce(sum(s.item_price), 0)::numeric, 2) as revenue_eur
    from public.sales s
    join public."vendingMachine" vm on vm.id = s.machine_id
    where vm.company = p_company_id and s.created_at >= v_window_start
    group by extract(dow from s.created_at)::int
  ) d;

  -- Company-wide hourly distribution
  select json_agg(h order by h.hour)
  into v_hourly_json
  from (
    select
      extract(hour from s.created_at)::int as hour,
      count(*)::int as total_sales,
      round(coalesce(sum(s.item_price), 0)::numeric, 2) as revenue_eur
    from public.sales s
    join public."vendingMachine" vm on vm.id = s.machine_id
    where vm.company = p_company_id and s.created_at >= v_window_start
    group by extract(hour from s.created_at)::int
  ) h;

  -- Trends
  v_trends_json := json_build_object(
    'current_revenue_eur', round(v_total_revenue::numeric, 2),
    'current_total_units', v_total_units,
    'prev_revenue_eur', round(v_prev_revenue::numeric, 2),
    'prev_total_units', v_prev_units,
    'revenue_change_pct', case when v_prev_revenue > 0
      then round(((v_total_revenue - v_prev_revenue)::numeric / v_prev_revenue) * 100, 1) else null end,
    'units_change_pct', case when v_prev_units > 0
      then round(((v_total_units - v_prev_units)::numeric / v_prev_units) * 100, 1) else null end
  );

  return json_build_object(
    'company', json_build_object('id', p_company_id, 'name', v_company_name),
    'period_days', p_days,
    'summary', json_build_object(
      'total_revenue_eur', round(v_total_revenue::numeric, 2),
      'total_units', v_total_units,
      'machine_count', v_machine_count,
      'avg_revenue_per_machine', case when v_machine_count > 0
        then round(v_total_revenue::numeric / v_machine_count, 2) else 0 end
    ),
    'machines', coalesce(v_machines_json, '[]'::json),
    'top_machines', coalesce(v_top_json, '[]'::json),
    'bottom_machines', coalesce(v_bottom_json, '[]'::json),
    'day_of_week_distribution', coalesce(v_dow_json, '[]'::json),
    'hourly_distribution', coalesce(v_hourly_json, '[]'::json),
    'trends', v_trends_json
  );
end;
$$;

grant execute on function get_company_insights_kpis(uuid, int) to authenticated;
grant execute on function get_company_insights_kpis(uuid, int) to service_role;

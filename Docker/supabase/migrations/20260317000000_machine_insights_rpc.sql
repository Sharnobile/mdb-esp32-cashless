-- AI Insights KPI aggregation RPC. Called by machine-insights edge function.
-- Returns pre-aggregated machine performance metrics for a single vending machine.
-- Uses security definer + manual company validation (not RLS) so the edge function
-- can call this safely via the service role client.

create or replace function get_machine_insights_kpis(
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
  v_window_start  timestamptz;
  v_machine_name  text;
  v_machine_status text;
  v_machine_exists boolean;
  v_total_units   bigint;
  v_total_revenue numeric;
  v_pax_count     bigint;
  v_conversion    numeric;
  v_trays_json    json;
  v_refills_json  json;
  v_summary_json  json;
  v_pax_json      json;
begin
  -- Time window
  v_window_start := now() - (p_days || ' days')::interval;

  -- Validate company ownership: vendingMachine.company must match p_company_id
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

  -- Return null if machine not found or wrong company
  if not found then
    return null;
  end if;

  -- ── Aggregate total units & revenue for summary ──────────────────────────────
  select
    coalesce(count(*), 0),
    coalesce(sum(item_price), 0)
  into
    v_total_units,
    v_total_revenue
  from public.sales
  where machine_id    = p_machine_id
    and created_at   >= v_window_start;

  -- ── Per-tray KPIs ─────────────────────────────────────────────────────────────
  select json_agg(tray_row order by t.item_number)
  into v_trays_json
  from (
    select
      mt.item_number,
      coalesce(p.name, 'Empty Slot')                                    as product_name,
      mt.product_id,
      mt.capacity,
      mt.current_stock,
      count(s.id)                                                         as units_sold,
      round(coalesce(sum(s.item_price), 0) / 100.0, 2)                   as revenue_eur,
      -- sell-through: units sold relative to theoretic weekly capacity over period
      round(
        case
          when mt.capacity > 0 and p_days > 0
          then least(count(s.id)::numeric / (mt.capacity::numeric * p_days / 7.0) * 100, 100)
          else 0
        end,
        1
      )                                                                   as sell_through_pct,
      -- avg daily units sold
      round(count(s.id)::numeric / p_days, 2)                            as avg_daily_units,
      -- days until empty based on current consumption rate
      case
        when count(s.id) > 0 and mt.current_stock > 0
        then round(mt.current_stock::numeric / (count(s.id)::numeric / p_days))
        when mt.current_stock = 0 then 0
        else null
      end                                                                 as days_until_empty,
      -- dead stock: slot configured but zero sales in period
      (count(s.id) = 0 and mt.capacity > 0)                             as is_dead_stock
    from public.machine_trays mt
    left join public.products p on p.id = mt.product_id
    left join public.sales s
      on  s.machine_id  = p_machine_id
      and s.item_number = mt.item_number
      and s.created_at >= v_window_start
    where mt.machine_id = p_machine_id
    group by mt.item_number, p.name, mt.product_id, mt.capacity, mt.current_stock
  ) as tray_row(
    item_number, product_name, product_id, capacity, current_stock,
    units_sold, revenue_eur, sell_through_pct, avg_daily_units,
    days_until_empty, is_dead_stock
  ),
  -- alias needed for ORDER BY
  public.machine_trays t
  where t.machine_id = p_machine_id
    and t.item_number = tray_row.item_number;

  -- ── Paxcounter ────────────────────────────────────────────────────────────────
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

  -- ── Refill history (last 5 outgoing_refill events for this machine) ───────────
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
    limit 5
  ) r;

  -- ── Summary ───────────────────────────────────────────────────────────────────
  v_summary_json := json_build_object(
    'total_revenue_eur',      round(v_total_revenue / 100.0, 2),
    'total_units',            v_total_units,
    'avg_daily_revenue_eur',  round((v_total_revenue / 100.0) / p_days, 2)
  );

  -- ── Assemble and return ───────────────────────────────────────────────────────
  return json_build_object(
    'machine',       json_build_object(
                       'id',     p_machine_id,
                       'name',   v_machine_name,
                       'status', v_machine_status
                     ),
    'period_days',   p_days,
    'summary',       v_summary_json,
    'trays',         coalesce(v_trays_json, '[]'::json),
    'paxcounter',    v_pax_json,
    'refill_history', coalesce(v_refills_json, '[]'::json)
  );
end;
$$;

-- Grant execute to authenticated users and service_role
-- (edge function calls this via service role; dashboard could call it directly as authenticated)
grant execute on function get_machine_insights_kpis(uuid, uuid, int) to authenticated;
grant execute on function get_machine_insights_kpis(uuid, uuid, int) to service_role;

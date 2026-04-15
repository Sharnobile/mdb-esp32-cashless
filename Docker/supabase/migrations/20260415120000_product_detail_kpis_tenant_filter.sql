-- Defense-in-depth: explicitly filter s_top CTE by caller's company via
-- vendingMachine.company. The current implementation relies on the implicit
-- invariant that a product belongs to exactly one company, but making the
-- tenant filter explicit removes that trust chain and documents intent.
--
-- No functional change under normal circumstances: every sale for the given
-- product is already on a machine in the product's company. This filter is
-- additive protection.

CREATE OR REPLACE FUNCTION public.get_product_detail_kpis(
  p_product_id uuid,
  p_days int DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_company_id    uuid;
  v_caller_co     uuid := public.my_company_id();
  v_velocity_days int;
  v_result        jsonb;
BEGIN
  -- Clamp p_days to a sane range (1 day to 10 years)
  p_days := GREATEST(1, LEAST(COALESCE(p_days, 30), 3650));

  IF v_caller_co IS NULL THEN
    RAISE EXCEPTION 'no authenticated caller';
  END IF;

  SELECT p.company INTO v_company_id
  FROM public.products p
  WHERE p.id = p_product_id;

  IF v_company_id IS NULL OR v_company_id IS DISTINCT FROM v_caller_co THEN
    RAISE EXCEPTION 'product not found or access denied';
  END IF;

  SELECT COALESCE(c.velocity_days, 30) INTO v_velocity_days
  FROM public.companies c
  WHERE c.id = v_caller_co;

  WITH
    wh AS (
      SELECT
        COALESCE(SUM(b.quantity), 0)::bigint                  AS warehouse_total_qty,
        COUNT(DISTINCT b.warehouse_id)::int                   AS warehouse_count
      FROM public.warehouse_stock_batches b
      WHERE b.product_id = p_product_id
        AND b.quantity > 0
    ),
    tr AS (
      SELECT
        COALESCE(SUM(mt.current_stock), 0)::bigint            AS tray_total_stock,
        COALESCE(SUM(mt.capacity), 0)::bigint                 AS tray_total_capacity,
        COUNT(DISTINCT mt.machine_id)::int                    AS machine_count
      FROM public.machine_trays mt
      WHERE mt.product_id = p_product_id
    ),
    s_today AS (
      SELECT
        COUNT(*)::bigint                                      AS units,
        COALESCE(SUM(s.item_price), 0)::numeric               AS revenue
      FROM public.sales s
      WHERE s.product_id = p_product_id
        AND s.created_at >= date_trunc('day', now())
    ),
    s_7d AS (
      SELECT
        COUNT(*)::bigint                                      AS units,
        COALESCE(SUM(s.item_price), 0)::numeric               AS revenue
      FROM public.sales s
      WHERE s.product_id = p_product_id
        AND s.created_at >= now() - interval '7 days'
    ),
    s_velocity AS (
      SELECT
        CASE WHEN v_velocity_days > 0
          THEN COUNT(*)::numeric / v_velocity_days
          ELSE 0
        END                                                   AS units_per_day
      FROM public.sales s
      WHERE s.product_id = p_product_id
        AND s.created_at >= now() - (v_velocity_days || ' days')::interval
    ),
    s_top AS (
      SELECT
        vm.id                                                 AS machine_id,
        vm.name                                               AS machine_name,
        COUNT(*)::bigint                                      AS units,
        COALESCE(SUM(s.item_price), 0)::numeric               AS revenue
      FROM public.sales s
      JOIN public."vendingMachine" vm
        ON vm.id = s.machine_id
        AND vm.company = v_caller_co  -- defense-in-depth tenant filter
      WHERE s.product_id = p_product_id
        AND s.created_at >= now() - (p_days || ' days')::interval
        AND s.machine_id IS NOT NULL
      GROUP BY vm.id, vm.name
      ORDER BY units DESC
      LIMIT 10
    )
  SELECT jsonb_build_object(
    'warehouse_total_qty',      (SELECT warehouse_total_qty FROM wh),
    'warehouse_count',          (SELECT warehouse_count FROM wh),
    'tray_total_stock',         (SELECT tray_total_stock FROM tr),
    'tray_total_capacity',      (SELECT tray_total_capacity FROM tr),
    'machine_count',            (SELECT machine_count FROM tr),
    'sales_today_units',        (SELECT units FROM s_today),
    'sales_today_revenue',      (SELECT revenue FROM s_today),
    'sales_7d_units',           (SELECT units FROM s_7d),
    'sales_7d_revenue',         (SELECT revenue FROM s_7d),
    'velocity_units_per_day',   (SELECT units_per_day FROM s_velocity),
    'velocity_window_days',     v_velocity_days,
    'top_machines',             COALESCE(
      (SELECT jsonb_agg(jsonb_build_object(
        'machine_id',   machine_id,
        'machine_name', machine_name,
        'units',        units,
        'revenue',      revenue
      )) FROM s_top),
      '[]'::jsonb
    )
  ) INTO v_result;

  RETURN v_result;
END
$$;

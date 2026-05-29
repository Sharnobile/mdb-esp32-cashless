-- =========================================================
-- Product-centric machine analysis: offering history + KPI RPC
-- =========================================================
-- Performance is a property of the PRODUCT, not the slot. Moving a product
-- between trays must neither split its sales record nor reset its trial clock.
--
--  • machine_product_offerings tracks since when a product has been offered in
--    a machine, regardless of which slot(s) it occupies. Moving between slots
--    keeps the offering open; only removing the product from every slot closes
--    it (a later re-add starts a fresh trial).
--  • get_machine_product_kpis aggregates sales by sales.product_id (snapshotted
--    at sale time) across all of a product's slots, server-side, so there is no
--    PostgREST row-limit truncation on busy machines.

-- ── A. Offering history table ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.machine_product_offerings (
  machine_id    uuid NOT NULL REFERENCES public."vendingMachine"(id) ON DELETE CASCADE,
  product_id    uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  offered_since timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT machine_product_offerings_pkey PRIMARY KEY (machine_id, product_id)
);

ALTER TABLE public.machine_product_offerings ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.machine_product_offerings TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.machine_product_offerings TO service_role;

DROP POLICY IF EXISTS "machine_product_offerings_select" ON public.machine_product_offerings;
CREATE POLICY "machine_product_offerings_select" ON public.machine_product_offerings
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public."vendingMachine" vm
      WHERE vm.id = machine_product_offerings.machine_id
        AND vm.company = public.my_company_id()
    )
  );

-- ── B. Maintenance trigger on machine_trays ──────────────────────────────────
-- Opens an offering when a product first appears in a machine; closes it when
-- the product no longer occupies any slot. SECURITY DEFINER so it can write the
-- offerings table on behalf of authenticated users editing trays.
CREATE OR REPLACE FUNCTION public.maintain_machine_product_offerings()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.product_id IS NOT NULL THEN
      INSERT INTO public.machine_product_offerings (machine_id, product_id, offered_since)
      VALUES (NEW.machine_id, NEW.product_id, now())
      ON CONFLICT (machine_id, product_id) DO NOTHING;
    END IF;

  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.product_id IS DISTINCT FROM OLD.product_id THEN
      IF NEW.product_id IS NOT NULL THEN
        INSERT INTO public.machine_product_offerings (machine_id, product_id, offered_since)
        VALUES (NEW.machine_id, NEW.product_id, now())
        ON CONFLICT (machine_id, product_id) DO NOTHING;
      END IF;
      IF OLD.product_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.machine_trays mt
        WHERE mt.machine_id = OLD.machine_id AND mt.product_id = OLD.product_id
      ) THEN
        DELETE FROM public.machine_product_offerings
        WHERE machine_id = OLD.machine_id AND product_id = OLD.product_id;
      END IF;
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.product_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.machine_trays mt
      WHERE mt.machine_id = OLD.machine_id AND mt.product_id = OLD.product_id
    ) THEN
      DELETE FROM public.machine_product_offerings
      WHERE machine_id = OLD.machine_id AND product_id = OLD.product_id;
    END IF;
  END IF;

  RETURN NULL; -- AFTER trigger
END;
$$;

DROP TRIGGER IF EXISTS on_tray_change_maintain_offerings ON public.machine_trays;
CREATE TRIGGER on_tray_change_maintain_offerings
  AFTER INSERT OR UPDATE OR DELETE ON public.machine_trays
  FOR EACH ROW EXECUTE FUNCTION public.maintain_machine_product_offerings();

-- ── C. Backfill existing offerings ───────────────────────────────────────────
-- Seed one offering per (machine, product) currently in trays, using the
-- earliest known assignment time (product_assigned_at, else slot created_at).
INSERT INTO public.machine_product_offerings (machine_id, product_id, offered_since)
SELECT mt.machine_id, mt.product_id, MIN(COALESCE(mt.product_assigned_at, mt.created_at))
FROM public.machine_trays mt
WHERE mt.product_id IS NOT NULL
GROUP BY mt.machine_id, mt.product_id
ON CONFLICT (machine_id, product_id) DO NOTHING;

-- ── D. Product-centric KPI aggregation RPC ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_machine_product_kpis(
  p_machine_id uuid,
  p_company_id uuid,
  p_days       int DEFAULT 30
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_window_start timestamptz;
  v_result       json;
BEGIN
  v_window_start := now() - (p_days || ' days')::interval;

  -- Validate company ownership
  PERFORM 1 FROM public."vendingMachine" vm
  WHERE vm.id = p_machine_id AND vm.company = p_company_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  WITH eff_sales AS (
    -- Attribute each sale to its snapshotted product_id; fall back to the slot's
    -- current product only for legacy sales that predate the snapshot column.
    SELECT COALESCE(s.product_id, mt2.product_id) AS product_id, s.item_price
    FROM public.sales s
    LEFT JOIN public.machine_trays mt2
      ON mt2.machine_id = p_machine_id AND mt2.item_number = s.item_number
    WHERE s.machine_id = p_machine_id
      AND s.created_at >= v_window_start
  ),
  sales_agg AS (
    SELECT product_id, count(*) AS units, coalesce(sum(item_price), 0) AS revenue
    FROM eff_sales
    WHERE product_id IS NOT NULL
    GROUP BY product_id
  ),
  tray_agg AS (
    SELECT mt.product_id,
           sum(mt.capacity)                       AS total_capacity,
           sum(mt.current_stock)                  AS total_stock,
           array_agg(mt.item_number ORDER BY mt.item_number) AS slots
    FROM public.machine_trays mt
    WHERE mt.machine_id = p_machine_id AND mt.product_id IS NOT NULL
    GROUP BY mt.product_id
  )
  SELECT json_agg(json_build_object(
    'product_id',     ta.product_id,
    'product_name',   coalesce(p.name, 'Unknown'),
    'units_sold',     coalesce(sa.units, 0),
    'revenue_eur',    round(coalesce(sa.revenue, 0)::numeric, 2),
    'total_capacity', ta.total_capacity,
    'total_stock',    ta.total_stock,
    'slots',          ta.slots,
    'offered_since',  o.offered_since
  ) ORDER BY coalesce(sa.units, 0) ASC)
  INTO v_result
  FROM tray_agg ta
  LEFT JOIN sales_agg sa ON sa.product_id = ta.product_id
  LEFT JOIN public.products p ON p.id = ta.product_id
  LEFT JOIN public.machine_product_offerings o
    ON o.machine_id = p_machine_id AND o.product_id = ta.product_id;

  RETURN json_build_object(
    'machine_id',  p_machine_id,
    'period_days', p_days,
    'products',    coalesce(v_result, '[]'::json)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_machine_product_kpis(uuid, uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_machine_product_kpis(uuid, uuid, int) TO service_role;

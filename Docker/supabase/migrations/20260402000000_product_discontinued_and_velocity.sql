-- =========================================================
-- Add discontinued flag to products + sales velocity RPC
-- =========================================================

-- A. Add discontinued column (backward-compatible: defaults to false)
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS discontinued boolean NOT NULL DEFAULT false;

-- B. RPC: get_product_sales_velocity
-- Returns average daily units sold per product over a given lookback period (default 30 days).
-- Joins sales → machine_trays → products to aggregate across all machines.
CREATE OR REPLACE FUNCTION public.get_product_sales_velocity(
  p_company_id uuid,
  p_days integer DEFAULT 30
)
RETURNS TABLE (
  product_id uuid,
  units_sold bigint,
  avg_daily_units numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
  SELECT
    mt.product_id,
    count(s.id)                                        AS units_sold,
    round(count(s.id)::numeric / greatest(p_days, 1), 2) AS avg_daily_units
  FROM public.sales s
  JOIN public.machine_trays mt
    ON mt.machine_id = s.machine_id
   AND mt.item_number = s.item_number
  JOIN public.products p
    ON p.id = mt.product_id
  WHERE p.company = p_company_id
    AND s.created_at >= (now() - make_interval(days => p_days))
  GROUP BY mt.product_id;
END;
$$;

-- Grant execute to authenticated users (RLS on underlying tables still applies for direct queries)
GRANT EXECUTE ON FUNCTION public.get_product_sales_velocity(uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_product_sales_velocity(uuid, integer) TO service_role;

-- C. Low-stock notification queue table
-- Edge function reads from here and sends push notifications, then marks rows as sent.
CREATE TABLE IF NOT EXISTS public.low_stock_notifications (
  id         uuid NOT NULL DEFAULT gen_random_uuid(),
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  warehouse_id uuid NOT NULL REFERENCES public.warehouses(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  product_name text,
  current_quantity integer NOT NULL DEFAULT 0,
  min_quantity integer NOT NULL DEFAULT 0,
  sent_at    timestamp with time zone,
  CONSTRAINT low_stock_notifications_pkey PRIMARY KEY (id)
);

ALTER TABLE public.low_stock_notifications ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.low_stock_notifications TO service_role;

-- RLS: only service_role operates on this table (via edge functions)
-- Authenticated users can read their own company's notifications
CREATE POLICY "low_stock_notifications_select" ON public.low_stock_notifications
  FOR SELECT TO authenticated
  USING (company_id = (SELECT public.my_company_id()));

-- D. Trigger function: enqueue low-stock notification when stock drops below minimum
-- Fires on UPDATE/DELETE of warehouse_stock_batches.
-- Checks total stock vs min_stock, and only queues if product is not discontinued
-- and no unsent notification already exists for this product+warehouse.
CREATE OR REPLACE FUNCTION public.check_low_stock_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_product_id uuid;
  v_warehouse_id uuid;
  v_company_id uuid;
  v_product_name text;
  v_discontinued boolean;
  v_total_quantity integer;
  v_min_quantity integer;
  v_existing_unsent bigint;
BEGIN
  -- Determine product_id and warehouse_id from the affected row
  IF TG_OP = 'DELETE' THEN
    v_product_id := OLD.product_id;
    v_warehouse_id := OLD.warehouse_id;
  ELSE
    v_product_id := NEW.product_id;
    v_warehouse_id := NEW.warehouse_id;
  END IF;

  -- Get product info
  SELECT p.company, p.name, p.discontinued
  INTO v_company_id, v_product_name, v_discontinued
  FROM public.products p
  WHERE p.id = v_product_id;

  -- Skip discontinued products
  IF v_discontinued THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- Get min stock for this product+warehouse
  SELECT pms.min_quantity INTO v_min_quantity
  FROM public.product_min_stock pms
  WHERE pms.product_id = v_product_id
    AND pms.warehouse_id = v_warehouse_id;

  -- If no min_stock configured, skip
  IF v_min_quantity IS NULL OR v_min_quantity <= 0 THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- Calculate total stock for this product in this warehouse
  SELECT COALESCE(SUM(wsb.quantity), 0) INTO v_total_quantity
  FROM public.warehouse_stock_batches wsb
  WHERE wsb.product_id = v_product_id
    AND wsb.warehouse_id = v_warehouse_id;

  -- Check if below minimum
  IF v_total_quantity <= v_min_quantity THEN
    -- Check for existing unsent notification (avoid duplicates)
    SELECT count(*) INTO v_existing_unsent
    FROM public.low_stock_notifications lsn
    WHERE lsn.product_id = v_product_id
      AND lsn.warehouse_id = v_warehouse_id
      AND lsn.sent_at IS NULL;

    IF v_existing_unsent = 0 THEN
      INSERT INTO public.low_stock_notifications
        (company_id, warehouse_id, product_id, product_name, current_quantity, min_quantity)
      VALUES
        (v_company_id, v_warehouse_id, v_product_id, v_product_name, v_total_quantity, v_min_quantity);
    END IF;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER on_stock_change_check_low_stock
  AFTER UPDATE OR DELETE ON public.warehouse_stock_batches
  FOR EACH ROW EXECUTE FUNCTION public.check_low_stock_notification();

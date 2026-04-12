-- =========================================================
-- Snapshot product_id on sales at INSERT time
--
-- Problem: sales reference products indirectly via
--   sales(machine_id, item_number) → machine_trays → products
-- This join is mutable — swapping which product sits in a tray
-- retroactively changes the entire sales history for that slot.
--
-- Fix: add product_id directly on sales, stamp it in the
-- BEFORE INSERT trigger (which already resolves the tray for
-- tax class), backfill existing sales, and update RPCs.
--
-- All changes are backward-compatible:
--   - product_id is nullable (old sales, manual sales without match)
--   - Frontend/iOS fall back to tray lookup for NULL product_id
--   - Firmware unaffected (product_id stamped server-side)
-- =========================================================


-- ─── A. Add column + FK + index ─────────────────────────────────────────────

ALTER TABLE public.sales
  ADD COLUMN IF NOT EXISTS product_id uuid REFERENCES public.products(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_sales_product_id ON public.sales(product_id);


-- ─── B. Update trigger: stamp product_id from tray lookup ───────────────────
--
-- Based on 20260411120000_fix_tax_trigger_round_cast.sql with one addition:
-- captures mt.product_id from the existing tray→product join in step 3b,
-- plus a standalone fallback lookup when the tax block is skipped.

CREATE OR REPLACE FUNCTION public.stamp_machine_and_decrement_stock()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_machine_id    uuid;
  v_rows_updated  integer;
  v_product_id    uuid;          -- NEW: snapshot product at sale time
  v_country       char(2);
  v_company_id    uuid;
  v_tax_class_id  uuid;
  v_tax_rate      numeric(6,4);
  v_tax_rate_num  numeric;
  v_price_num     numeric;
  v_price_net     numeric(10,4);
BEGIN
  -- -------------------------------------------------------
  -- 1. Resolve machine_id
  -- -------------------------------------------------------
  IF NEW.machine_id IS NOT NULL THEN
    v_machine_id := NEW.machine_id;
  ELSE
    SELECT vm.id INTO v_machine_id
    FROM public."vendingMachine" vm
    WHERE vm.embedded = NEW.embedded_id
    LIMIT 1;

    NEW.machine_id := v_machine_id;
  END IF;

  -- -------------------------------------------------------
  -- 2. Decrement tray stock
  -- -------------------------------------------------------
  IF v_machine_id IS NOT NULL THEN
    UPDATE public.machine_trays
    SET current_stock = greatest(0, current_stock - 1)
    WHERE machine_id = v_machine_id
      AND item_number = NEW.item_number;

    GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

    IF v_rows_updated = 0 THEN
      INSERT INTO public.stock_decrement_log
        (embedded_id, machine_id, item_number, item_price, reason, sale_created_at)
      VALUES
        (NEW.embedded_id, v_machine_id, NEW.item_number, NEW.item_price,
         'no_matching_tray', NEW.created_at);
    END IF;
  ELSE
    INSERT INTO public.stock_decrement_log
      (embedded_id, machine_id, item_number, item_price, reason, sale_created_at)
    VALUES
      (NEW.embedded_id, NULL, NEW.item_number, NEW.item_price,
       'no_machine_for_device', NEW.created_at);
  END IF;

  -- -------------------------------------------------------
  -- 3. Stamp tax data + product_id (only if machine was resolved)
  -- -------------------------------------------------------
  IF v_machine_id IS NOT NULL AND NEW.item_price IS NOT NULL THEN
    -- 3a. Resolve company_id and country
    SELECT
      vm.company,
      COALESCE(vm.country_code, c.country_code, 'DE')
    INTO v_company_id, v_country
    FROM public."vendingMachine" vm
    JOIN public.companies c ON c.id = vm.company
    WHERE vm.id = v_machine_id;

    -- 3b. Resolve product_id + tax_class_id via tray → product
    --     (CHANGED: also captures mt.product_id in the same query)
    IF v_company_id IS NOT NULL THEN
      SELECT mt.product_id, COALESCE(p.tax_class_id, pc.tax_class_id)
      INTO v_product_id, v_tax_class_id
      FROM public.machine_trays mt
      JOIN public.products p ON p.id = mt.product_id
      LEFT JOIN public.product_category pc ON pc.id = p.category
      WHERE mt.machine_id = v_machine_id
        AND mt.item_number = NEW.item_number
      LIMIT 1;
    END IF;

    -- 3c. Look up applicable tax rate
    IF v_tax_class_id IS NOT NULL AND v_company_id IS NOT NULL THEN
      SELECT tr.rate INTO v_tax_rate
      FROM public.tax_rates tr
      WHERE tr.company_id = v_company_id
        AND tr.tax_class_id = v_tax_class_id
        AND tr.country_code = v_country
        AND tr.valid_from <= COALESCE(NEW.created_at, now())::date
        AND (tr.valid_to IS NULL OR tr.valid_to >= COALESCE(NEW.created_at, now())::date)
      ORDER BY tr.valid_from DESC
      LIMIT 1;
    END IF;

    -- 3d. Calculate and stamp tax if rate found
    IF v_tax_rate IS NOT NULL THEN
      v_tax_rate_num := v_tax_rate::numeric;
      v_price_num    := NEW.item_price::numeric;

      v_price_net := ROUND(v_price_num / (1::numeric + v_tax_rate_num), 4);
      NEW.tax_rate_snapshot := v_tax_rate;
      NEW.price_net := v_price_net;
      NEW.tax_amount := ROUND(v_price_num - v_price_net::numeric, 4);
    END IF;

  ELSIF v_machine_id IS NOT NULL THEN
    -- Fallback: item_price IS NULL skipped the tax block above,
    -- but we still want product_id if a matching tray exists.
    SELECT mt.product_id INTO v_product_id
    FROM public.machine_trays mt
    WHERE mt.machine_id = v_machine_id
      AND mt.item_number = NEW.item_number
    LIMIT 1;
  END IF;

  -- -------------------------------------------------------
  -- 4. Stamp product_id (immutable snapshot of what was sold)
  -- -------------------------------------------------------
  NEW.product_id := v_product_id;

  RETURN NEW;
END
$$;


-- ─── C. Backfill existing sales ─────────────────────────────────────────────
-- Best-effort: uses CURRENT tray→product mapping. Sales where the tray was
-- reconfigured since the sale will get the current product — we cannot
-- reconstruct the historical assignment. Going forward, the trigger above
-- stamps the correct product_id at INSERT time.

UPDATE public.sales s
SET product_id = mt.product_id
FROM public.machine_trays mt
WHERE mt.machine_id = s.machine_id
  AND mt.item_number = s.item_number
  AND s.product_id IS NULL
  AND mt.product_id IS NOT NULL;


-- ─── D. Update insert_manual_sale to include product_id in output ───────────

CREATE OR REPLACE FUNCTION public.insert_manual_sale(
  p_machine_id uuid,
  p_item_number integer,
  p_item_price float8,
  p_channel text,
  p_created_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_company_id uuid;
  v_new_sale RECORD;
BEGIN
  -- Verify caller is admin
  IF NOT public.i_am_admin() THEN
    RAISE EXCEPTION 'only admins can insert manual sales';
  END IF;

  -- Verify the machine belongs to the caller's company
  SELECT vm.company INTO v_company_id
  FROM public."vendingMachine" vm
  WHERE vm.id = p_machine_id;

  IF v_company_id IS NULL OR v_company_id != public.my_company_id() THEN
    RAISE EXCEPTION 'machine does not belong to your company';
  END IF;

  -- Insert the sale with machine_id pre-set.
  -- The BEFORE INSERT trigger will see machine_id is NOT NULL,
  -- skip embedded_id lookup, decrement tray stock, and stamp product_id.
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
  VALUES (p_machine_id, p_item_number, p_item_price, p_channel, p_created_at)
  RETURNING id, created_at, machine_id, item_number, item_price, channel, product_id
  INTO v_new_sale;

  RETURN jsonb_build_object(
    'id', v_new_sale.id,
    'created_at', v_new_sale.created_at,
    'machine_id', v_new_sale.machine_id,
    'item_number', v_new_sale.item_number,
    'item_price', v_new_sale.item_price,
    'channel', v_new_sale.channel,
    'product_id', v_new_sale.product_id
  );
END;
$$;


-- ─── E. Update backfill_sales_tax to also fill product_id ───────────────────
-- Uses COALESCE so an already-correct product_id is never overwritten
-- by a potentially-wrong current tray mapping.

CREATE OR REPLACE FUNCTION public.backfill_sales_tax(p_company_id uuid)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_updated integer;
BEGIN
  -- Verify caller belongs to this company
  IF p_company_id != public.my_company_id() THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  UPDATE public.sales s
  SET
    tax_rate_snapshot = sub.rate,
    price_net = ROUND(s.item_price::numeric / (1 + sub.rate), 4),
    tax_amount = ROUND(s.item_price::numeric - ROUND(s.item_price::numeric / (1 + sub.rate), 4), 4),
    product_id = COALESCE(s.product_id, sub.product_id)
  FROM (
    SELECT DISTINCT ON (s2.id)
      s2.id AS sale_id,
      tr.rate,
      mt.product_id
    FROM public.sales s2
    JOIN public."vendingMachine" vm ON vm.id = s2.machine_id
    JOIN public.companies c ON c.id = vm.company
    JOIN public.machine_trays mt ON mt.machine_id = vm.id AND mt.item_number = s2.item_number
    JOIN public.products p ON p.id = mt.product_id
    LEFT JOIN public.product_category pc ON pc.id = p.category
    JOIN public.tax_rates tr
      ON tr.company_id = p_company_id
      AND tr.tax_class_id = COALESCE(p.tax_class_id, pc.tax_class_id)
      AND tr.country_code = COALESCE(vm.country_code, c.country_code, 'DE')
      AND tr.valid_from <= s2.created_at::date
      AND (tr.valid_to IS NULL OR tr.valid_to >= s2.created_at::date)
    WHERE s2.tax_rate_snapshot IS NULL
      AND s2.item_price IS NOT NULL
      AND vm.company = p_company_id
      AND COALESCE(p.tax_class_id, pc.tax_class_id) IS NOT NULL
    ORDER BY s2.id, tr.valid_from DESC
  ) sub
  WHERE s.id = sub.sale_id;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END
$$;

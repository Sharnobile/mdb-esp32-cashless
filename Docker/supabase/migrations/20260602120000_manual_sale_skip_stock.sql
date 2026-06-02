-- =========================================================
-- Manual sale: optional stock-skip
--
-- Adds an opt-out of the BEFORE-INSERT stock decrement so historical
-- sales (e.g. Nayax reconciliation imports, where stock was already
-- accounted for at refill) can be recorded WITHOUT changing current_stock.
--
-- Mechanism: insert_manual_sale(p_adjust_stock => false) sets a
-- transaction-local GUC; stamp_machine_and_decrement_stock() skips ONLY
-- its stock-decrement step when that GUC is 'on'. machine_id resolution,
-- tax snapshot, and product_id stamping are unaffected.
--
-- Backward-compatible: GUC unset => decrement (today's behaviour) for every
-- normal insert (MQTT firmware sales never set it); p_adjust_stock DEFAULT
-- true => all existing callers unchanged. Idempotent (CREATE OR REPLACE /
-- DROP IF EXISTS) so safe to re-run via update.sh.
-- =========================================================

-- 1. Trigger: guard ONLY the stock-decrement step --------------------------
CREATE OR REPLACE FUNCTION public.stamp_machine_and_decrement_stock()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_machine_id    uuid;
  v_rows_updated  integer;
  v_product_id    uuid;
  v_country       char(2);
  v_company_id    uuid;
  v_tax_class_id  uuid;
  v_tax_rate      numeric(6,4);
  v_tax_rate_num  numeric;
  v_price_num     numeric;
  v_price_net     numeric(10,4);
BEGIN
  -- 1. Resolve machine_id
  IF NEW.machine_id IS NOT NULL THEN
    v_machine_id := NEW.machine_id;
  ELSE
    SELECT vm.id INTO v_machine_id
    FROM public."vendingMachine" vm
    WHERE vm.embedded = NEW.embedded_id
    LIMIT 1;

    NEW.machine_id := v_machine_id;
  END IF;

  -- 2. Decrement tray stock — skippable via transaction-local GUC set by
  --    insert_manual_sale(p_adjust_stock => false).
  IF coalesce(current_setting('vmflow.skip_stock_decrement', true), 'off') <> 'on' THEN
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
  END IF;

  -- 3. Stamp tax data + product_id (only if machine was resolved)
  IF v_machine_id IS NOT NULL AND NEW.item_price IS NOT NULL THEN
    SELECT
      vm.company,
      COALESCE(vm.country_code, c.country_code, 'DE')
    INTO v_company_id, v_country
    FROM public."vendingMachine" vm
    JOIN public.companies c ON c.id = vm.company
    WHERE vm.id = v_machine_id;

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

    IF v_tax_rate IS NOT NULL THEN
      v_tax_rate_num := v_tax_rate::numeric;
      v_price_num    := NEW.item_price::numeric;

      v_price_net := ROUND(v_price_num / (1::numeric + v_tax_rate_num), 4);
      NEW.tax_rate_snapshot := v_tax_rate;
      NEW.price_net := v_price_net;
      NEW.tax_amount := ROUND(v_price_num - v_price_net::numeric, 4);
    END IF;

  ELSIF v_machine_id IS NOT NULL THEN
    SELECT mt.product_id INTO v_product_id
    FROM public.machine_trays mt
    WHERE mt.machine_id = v_machine_id
      AND mt.item_number = NEW.item_number
    LIMIT 1;
  END IF;

  -- 4. Stamp product_id (immutable snapshot of what was sold)
  NEW.product_id := v_product_id;

  RETURN NEW;
END
$$;

-- 2. insert_manual_sale gains p_adjust_stock (DROP+CREATE: the new defaulted
--    param would otherwise create an ambiguous overload with the old 5-arg fn)
DROP FUNCTION IF EXISTS public.insert_manual_sale(uuid, integer, float8, text, timestamptz);

CREATE OR REPLACE FUNCTION public.insert_manual_sale(
  p_machine_id uuid,
  p_item_number integer,
  p_item_price float8,
  p_channel text,
  p_created_at timestamptz DEFAULT now(),
  p_adjust_stock boolean DEFAULT true
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
  IF NOT public.i_am_admin() THEN
    RAISE EXCEPTION 'only admins can insert manual sales';
  END IF;

  SELECT vm.company INTO v_company_id
  FROM public."vendingMachine" vm
  WHERE vm.id = p_machine_id;

  IF v_company_id IS NULL OR v_company_id != public.my_company_id() THEN
    RAISE EXCEPTION 'machine does not belong to your company';
  END IF;

  -- Opt out of the trigger's stock decrement for THIS insert (transaction-local).
  IF NOT p_adjust_stock THEN
    PERFORM set_config('vmflow.skip_stock_decrement', 'on', true);
  END IF;

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

-- Re-grant EXECUTE (DROP removed the grants from 20260403; do not rely on
-- ALTER DEFAULT PRIVILEGES being configured on every install).
GRANT EXECUTE ON FUNCTION public.insert_manual_sale(uuid, integer, float8, text, timestamptz, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.insert_manual_sale(uuid, integer, float8, text, timestamptz, boolean) TO service_role;

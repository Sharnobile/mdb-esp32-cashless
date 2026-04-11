-- =========================================================
-- Fix: stamp_machine_and_decrement_stock — explicit ::numeric casts
--
-- Background:
-- Migration 20260406000000_tax_infrastructure.sql installed a tax-stamping
-- version of stamp_machine_and_decrement_stock that calls
--   ROUND(NEW.item_price::numeric / (1 + v_tax_rate), 4)
--   ROUND(NEW.item_price::numeric - v_price_net, 4)
-- and relies on those ::numeric casts to pick Postgres' round(numeric, integer)
-- overload instead of the non-existent round(double precision, integer).
--
-- On at least one production database the running function body was observed
-- to raise
--   ERROR: function round(double precision, integer) does not exist
-- whenever a sale INSERT triggered the tax-stamping branch, breaking the
-- entire MQTT sales pipeline (mqtt-webhook edge function → PostgREST → trigger).
-- The root cause on that DB was that the function definition in pg_proc had
-- diverged from the migration source (manual override, partial apply, or
-- similar), and because 20260406000000 was already marked as applied in the
-- _migrations tracking table, update.sh would not re-run it.
--
-- This migration re-applies the function definition with an unambiguous
-- numeric-typed computation. It is:
--   - idempotent (CREATE OR REPLACE)
--   - a no-op on a DB that already has the correct body
--   - restores the tax-stamping code path to working order on any DB that
--     drifted for whatever reason
--
-- Belt and braces: v_tax_rate_num is explicitly cast to numeric right after
-- the SELECT, so the whole expression stays in numeric space regardless of
-- what the source column of tax_rates.rate turns out to be on this DB.
-- =========================================================

CREATE OR REPLACE FUNCTION public.stamp_machine_and_decrement_stock()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_machine_id    uuid;
  v_rows_updated  integer;
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
  -- 2. Decrement tray stock (unchanged from tax_infrastructure)
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
  -- 3. Stamp tax data (only if machine was resolved)
  --    All arithmetic stays in numeric space so that the
  --    ROUND(numeric, integer) overload is selected.
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

    -- 3b. Resolve tax_class_id via tray → product → COALESCE(product.tax_class_id, category.tax_class_id)
    IF v_company_id IS NOT NULL THEN
      SELECT COALESCE(p.tax_class_id, pc.tax_class_id)
      INTO v_tax_class_id
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

    -- 3d. Calculate and stamp if rate found.
    --     Force both operands into numeric(∞,∞) up front — this is the belt
    --     and braces bit. Even if tax_rates.rate somehow ends up as float8
    --     on a drifted DB, the explicit CAST keeps the whole expression in
    --     numeric space so ROUND(numeric, integer) is the resolved overload.
    IF v_tax_rate IS NOT NULL THEN
      v_tax_rate_num := v_tax_rate::numeric;
      v_price_num    := NEW.item_price::numeric;

      v_price_net := ROUND(v_price_num / (1::numeric + v_tax_rate_num), 4);
      NEW.tax_rate_snapshot := v_tax_rate;
      NEW.price_net := v_price_net;
      NEW.tax_amount := ROUND(v_price_num - v_price_net::numeric, 4);
    END IF;
    -- If no rate found, all three columns remain NULL (graceful fallback)
  END IF;

  RETURN NEW;
END
$$;

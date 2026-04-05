-- =========================================================
-- Tax Infrastructure
--
-- Adds tax classes, tax rates, and system reference rates
-- for tax-compliant sales recording and export (DATEV, CSV).
--
-- Changes:
-- 1. New table: tax_classes (per-company semantic tax categories)
-- 2. New table: tax_rates (per-company rates with temporal validity)
-- 3. New table: system_tax_rates (read-only EU reference rates)
-- 4. New columns on product_category, products, companies,
--    vendingMachine, sales
-- 5. Updated trigger: stamp tax data on sales INSERT
-- =========================================================

-- =========================================================
-- A. tax_classes — semantic tax categories per company
-- =========================================================
CREATE TABLE IF NOT EXISTS public.tax_classes (
  id          uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  created_at  timestamptz NOT NULL DEFAULT now(),
  company_id  uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  name        text NOT NULL,
  description text,
  sort_order  int NOT NULL DEFAULT 0,
  UNIQUE (company_id, name)
);

ALTER TABLE public.tax_classes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tax_classes_select" ON public.tax_classes
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());

CREATE POLICY "tax_classes_insert" ON public.tax_classes
  FOR INSERT TO authenticated
  WITH CHECK (company_id = public.my_company_id());

CREATE POLICY "tax_classes_update" ON public.tax_classes
  FOR UPDATE TO authenticated
  USING (company_id = public.my_company_id())
  WITH CHECK (company_id = public.my_company_id());

CREATE POLICY "tax_classes_delete" ON public.tax_classes
  FOR DELETE TO authenticated
  USING (company_id = public.my_company_id());


-- =========================================================
-- B. tax_rates — actual rates per company, class, country
-- =========================================================
CREATE TABLE IF NOT EXISTS public.tax_rates (
  id            uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  created_at    timestamptz NOT NULL DEFAULT now(),
  company_id    uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  tax_class_id  uuid NOT NULL REFERENCES public.tax_classes(id) ON DELETE CASCADE,
  country_code  char(2) NOT NULL DEFAULT 'DE',
  rate          numeric(6,4) NOT NULL,
  name          text NOT NULL,
  valid_from    date NOT NULL DEFAULT CURRENT_DATE,
  valid_to      date,
  is_inclusive  boolean NOT NULL DEFAULT true,
  UNIQUE (company_id, tax_class_id, country_code, valid_from)
);

ALTER TABLE public.tax_rates ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tax_rates_select" ON public.tax_rates
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());

CREATE POLICY "tax_rates_insert" ON public.tax_rates
  FOR INSERT TO authenticated
  WITH CHECK (company_id = public.my_company_id());

CREATE POLICY "tax_rates_update" ON public.tax_rates
  FOR UPDATE TO authenticated
  USING (company_id = public.my_company_id())
  WITH CHECK (company_id = public.my_company_id());

CREATE POLICY "tax_rates_delete" ON public.tax_rates
  FOR DELETE TO authenticated
  USING (company_id = public.my_company_id());


-- =========================================================
-- C. system_tax_rates — read-only EU reference rates
-- =========================================================
CREATE TABLE IF NOT EXISTS public.system_tax_rates (
  id              serial PRIMARY KEY,
  country_code    char(2) NOT NULL,
  tax_class_name  text NOT NULL,
  rate            numeric(6,4) NOT NULL,
  name            text NOT NULL,
  valid_from      date NOT NULL,
  valid_to        date,
  UNIQUE (country_code, tax_class_name, valid_from)
);

ALTER TABLE public.system_tax_rates ENABLE ROW LEVEL SECURITY;

-- Read-only for all authenticated users (reference data)
CREATE POLICY "system_tax_rates_select" ON public.system_tax_rates
  FOR SELECT TO authenticated
  USING (true);


-- =========================================================
-- D. Add columns to existing tables
-- =========================================================

-- product_category: link to tax class
ALTER TABLE public.product_category
  ADD COLUMN IF NOT EXISTS tax_class_id uuid REFERENCES public.tax_classes(id) ON DELETE SET NULL;

-- products: optional tax class override (NULL = inherit from category)
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS tax_class_id uuid REFERENCES public.tax_classes(id) ON DELETE SET NULL;

-- companies: default country code
ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS country_code char(2) DEFAULT 'DE';

-- vendingMachine: country override (NULL = inherit from company)
ALTER TABLE public."vendingMachine"
  ADD COLUMN IF NOT EXISTS country_code char(2);

-- sales: stamped tax data
ALTER TABLE public.sales
  ADD COLUMN IF NOT EXISTS tax_rate_snapshot numeric(6,4);

ALTER TABLE public.sales
  ADD COLUMN IF NOT EXISTS tax_amount numeric(10,4);

ALTER TABLE public.sales
  ADD COLUMN IF NOT EXISTS price_net numeric(10,4);


-- =========================================================
-- E. Update trigger: stamp tax data on sales INSERT
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
  v_price_net     numeric(10,4);
BEGIN
  -- -------------------------------------------------------
  -- 1. Resolve machine_id (existing logic, unchanged)
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
  -- 2. Decrement tray stock (existing logic, unchanged)
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
  -- 3. Stamp tax data (NEW logic)
  --    Only runs if machine was resolved; never blocks the sale.
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

    -- 3d. Calculate and stamp if rate found
    IF v_tax_rate IS NOT NULL THEN
      v_price_net := ROUND(NEW.item_price / (1 + v_tax_rate), 4);
      NEW.tax_rate_snapshot := v_tax_rate;
      NEW.price_net := v_price_net;
      NEW.tax_amount := ROUND(NEW.item_price - v_price_net, 4);
    END IF;
    -- If no rate found, all three columns remain NULL (graceful fallback)
  END IF;

  RETURN NEW;
END
$$;

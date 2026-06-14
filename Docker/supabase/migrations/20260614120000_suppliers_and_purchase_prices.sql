-- Purchase prices & suppliers (Einkaufspreise / Lieferanten).
-- Two company-scoped tables, RLS modeled on tax_classes (20260406000000).
-- Additive only; safe on every existing install.

-- 1. suppliers ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.suppliers (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  name       text NOT NULL,
  CONSTRAINT suppliers_name_not_blank CHECK (length(btrim(name)) > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS suppliers_company_lower_name_uq
  ON public.suppliers (company_id, lower(btrim(name)));

ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "suppliers_select" ON public.suppliers;
CREATE POLICY "suppliers_select" ON public.suppliers
  FOR SELECT TO authenticated USING (company_id = public.my_company_id());
DROP POLICY IF EXISTS "suppliers_insert" ON public.suppliers;
CREATE POLICY "suppliers_insert" ON public.suppliers
  FOR INSERT TO authenticated WITH CHECK (company_id = public.my_company_id());
DROP POLICY IF EXISTS "suppliers_update" ON public.suppliers;
CREATE POLICY "suppliers_update" ON public.suppliers
  FOR UPDATE TO authenticated
  USING (company_id = public.my_company_id())
  WITH CHECK (company_id = public.my_company_id());
DROP POLICY IF EXISTS "suppliers_delete" ON public.suppliers;
CREATE POLICY "suppliers_delete" ON public.suppliers
  FOR DELETE TO authenticated USING (company_id = public.my_company_id());

-- 2. product_purchase_prices --------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_purchase_prices (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at  timestamptz NOT NULL DEFAULT now(),
  company_id  uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  product_id  uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  supplier_id uuid NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  price_net   numeric(10,4) NOT NULL,
  price_gross numeric(10,4) NOT NULL,
  price_basis text NOT NULL CHECK (price_basis IN ('net','gross')),
  tax_rate    numeric(6,4) NOT NULL,
  observed_on date NOT NULL DEFAULT CURRENT_DATE,
  note        text
);

CREATE INDEX IF NOT EXISTS product_purchase_prices_product_idx
  ON public.product_purchase_prices (product_id, observed_on DESC, created_at DESC);

ALTER TABLE public.product_purchase_prices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ppp_select" ON public.product_purchase_prices;
CREATE POLICY "ppp_select" ON public.product_purchase_prices
  FOR SELECT TO authenticated USING (company_id = public.my_company_id());
DROP POLICY IF EXISTS "ppp_insert" ON public.product_purchase_prices;
CREATE POLICY "ppp_insert" ON public.product_purchase_prices
  FOR INSERT TO authenticated WITH CHECK (company_id = public.my_company_id());
DROP POLICY IF EXISTS "ppp_update" ON public.product_purchase_prices;
CREATE POLICY "ppp_update" ON public.product_purchase_prices
  FOR UPDATE TO authenticated
  USING (company_id = public.my_company_id())
  WITH CHECK (company_id = public.my_company_id());
DROP POLICY IF EXISTS "ppp_delete" ON public.product_purchase_prices;
CREATE POLICY "ppp_delete" ON public.product_purchase_prices
  FOR DELETE TO authenticated USING (company_id = public.my_company_id());

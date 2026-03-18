-- ═══════════════════════════════════════════════════════════════════════════
-- Warehouse Product Positions
-- Stores the physical order/location of products within each warehouse
-- so refill pick lists can be sorted to match the warehouse layout.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Table ────────────────────────────────────────────────────────────────────
CREATE TABLE public.warehouse_product_positions (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  company_id      uuid        NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  warehouse_id    uuid        NOT NULL REFERENCES public.warehouses(id) ON DELETE CASCADE,
  product_id      uuid        NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  sort_order      integer     NOT NULL DEFAULT 0,
  location_label  text,
  UNIQUE(warehouse_id, product_id)
);

-- ── Indexes ──────────────────────────────────────────────────────────────────
CREATE INDEX idx_wpp_warehouse_sort ON public.warehouse_product_positions (warehouse_id, sort_order);

-- ── RLS ──────────────────────────────────────────────────────────────────────
ALTER TABLE public.warehouse_product_positions ENABLE ROW LEVEL SECURITY;

CREATE POLICY wpp_select ON public.warehouse_product_positions
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());

CREATE POLICY wpp_insert ON public.warehouse_product_positions
  FOR INSERT TO authenticated
  WITH CHECK (company_id = (SELECT public.my_company_id()) AND (SELECT public.i_am_admin()));

CREATE POLICY wpp_update ON public.warehouse_product_positions
  FOR UPDATE TO authenticated
  USING (company_id = (SELECT public.my_company_id()) AND (SELECT public.i_am_admin()));

CREATE POLICY wpp_delete ON public.warehouse_product_positions
  FOR DELETE TO authenticated
  USING (company_id = (SELECT public.my_company_id()) AND (SELECT public.i_am_admin()));

-- ── Grants ───────────────────────────────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE, DELETE ON public.warehouse_product_positions TO authenticated;
GRANT ALL ON public.warehouse_product_positions TO service_role;

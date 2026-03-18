-- ═══════════════════════════════════════════════════════════════════════════
-- Warehouse Position Groups (folder-like structure for product positions)
-- Groups can nest via parent_id for multi-level hierarchy.
-- Products reference a group via warehouse_product_positions.group_id.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Groups table ────────────────────────────────────────────────────────────
CREATE TABLE public.warehouse_position_groups (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at   timestamptz NOT NULL DEFAULT now(),
  company_id   uuid        NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  warehouse_id uuid        NOT NULL REFERENCES public.warehouses(id) ON DELETE CASCADE,
  parent_id    uuid        REFERENCES public.warehouse_position_groups(id) ON DELETE CASCADE,
  name         text        NOT NULL,
  sort_order   integer     NOT NULL DEFAULT 0
);

-- ── Indexes ──────────────────────────────────────────────────────────────────
CREATE INDEX idx_wpg_warehouse_parent_sort
  ON public.warehouse_position_groups (warehouse_id, parent_id, sort_order);

-- ── RLS ──────────────────────────────────────────────────────────────────────
ALTER TABLE public.warehouse_position_groups ENABLE ROW LEVEL SECURITY;

CREATE POLICY wpg_select ON public.warehouse_position_groups
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());

CREATE POLICY wpg_insert ON public.warehouse_position_groups
  FOR INSERT TO authenticated
  WITH CHECK (company_id = (SELECT public.my_company_id()) AND (SELECT public.i_am_admin()));

CREATE POLICY wpg_update ON public.warehouse_position_groups
  FOR UPDATE TO authenticated
  USING (company_id = (SELECT public.my_company_id()) AND (SELECT public.i_am_admin()));

CREATE POLICY wpg_delete ON public.warehouse_position_groups
  FOR DELETE TO authenticated
  USING (company_id = (SELECT public.my_company_id()) AND (SELECT public.i_am_admin()));

-- ── Grants ───────────────────────────────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE, DELETE ON public.warehouse_position_groups TO authenticated;
GRANT ALL ON public.warehouse_position_groups TO service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- Add group_id to warehouse_product_positions
-- ═══════════════════════════════════════════════════════════════════════════
ALTER TABLE public.warehouse_product_positions
  ADD COLUMN group_id uuid REFERENCES public.warehouse_position_groups(id) ON DELETE SET NULL;

CREATE INDEX idx_wpp_group ON public.warehouse_product_positions (group_id);

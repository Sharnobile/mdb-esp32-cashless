-- =========================================================
-- Deal User State (archived / pinned)
--
-- Per-user, per-deal annotations:
--   - archived_at: user dismissed an offer (uninteresting,
--                  wrong product matched, …) → hidden from
--                  the default deals list
--   - pinned_at:   user wants the offer at the top of the list
--
-- Keyed by (retailer, offer_id) — the stable external identity
-- of the offer — because deal_cache rows are rewritten on every
-- /deals refresh (DELETE + INSERT in deal-search edge function),
-- so deal_cache.id is not stable and cannot be referenced.
-- =========================================================

CREATE TABLE IF NOT EXISTS public.deal_user_state (
  user_id     uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  company_id  uuid        NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  retailer    text        NOT NULL,
  offer_id    text        NOT NULL,
  archived_at timestamptz NULL,
  pinned_at   timestamptz NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, company_id, retailer, offer_id)
);

CREATE INDEX IF NOT EXISTS idx_deal_user_state_company_user
  ON public.deal_user_state (company_id, user_id);

CREATE OR REPLACE FUNCTION public.tg_deal_user_state_set_updated_at()
  RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS deal_user_state_set_updated_at ON public.deal_user_state;
CREATE TRIGGER deal_user_state_set_updated_at
  BEFORE UPDATE ON public.deal_user_state
  FOR EACH ROW EXECUTE FUNCTION public.tg_deal_user_state_set_updated_at();

ALTER TABLE public.deal_user_state ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.deal_user_state TO authenticated;
GRANT ALL ON public.deal_user_state TO service_role;

DROP POLICY IF EXISTS "deal_user_state_select" ON public.deal_user_state;
CREATE POLICY "deal_user_state_select" ON public.deal_user_state
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() AND company_id = public.my_company_id());

DROP POLICY IF EXISTS "deal_user_state_insert" ON public.deal_user_state;
CREATE POLICY "deal_user_state_insert" ON public.deal_user_state
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND company_id = public.my_company_id());

DROP POLICY IF EXISTS "deal_user_state_update" ON public.deal_user_state;
CREATE POLICY "deal_user_state_update" ON public.deal_user_state
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid() AND company_id = public.my_company_id())
  WITH CHECK (user_id = auth.uid() AND company_id = public.my_company_id());

DROP POLICY IF EXISTS "deal_user_state_delete" ON public.deal_user_state;
CREATE POLICY "deal_user_state_delete" ON public.deal_user_state
  FOR DELETE TO authenticated
  USING (user_id = auth.uid() AND company_id = public.my_company_id());

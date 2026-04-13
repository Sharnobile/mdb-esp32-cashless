-- =========================================================
-- Deal Search Infrastructure
--
-- Adds per-company deal search feature:
--   1. companies.deals_enabled  – feature toggle (default off)
--   2. companies.deals_zip_code – PLZ for regional offers
--   3. deal_cache table         – cached retailer offers matched to products
--
-- The deal-search edge function queries external offer APIs
-- (e.g. marktguru.de), fuzzy-matches results against the
-- company's product catalog, and caches matches here.
-- =========================================================


-- ─── A. Company-level settings ──────────────────────────────────────────────

ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS deals_enabled boolean NOT NULL DEFAULT false;

ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS deals_zip_code text;


-- ─── B. Deal cache table ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.deal_cache (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at     timestamptz NOT NULL DEFAULT now(),
  company_id     uuid        NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  product_id     uuid        NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  retailer       text        NOT NULL,
  deal_title     text        NOT NULL,
  deal_price     numeric(10,2),
  regular_price  numeric(10,2),
  discount_pct   numeric(5,2),
  valid_from     date,
  valid_until    date,
  source_url     text,
  image_url      text,
  image_url_large text,                       -- large prospekt image from offer API
  external_url   text,                        -- link to retailer page (if available)
  matched_by     text        NOT NULL,        -- 'name_fuzzy'
  confidence     numeric(3,2),                -- 0.00–1.00
  matched_tokens text[],                      -- which tokens matched (for validation UI)
  fetched_at     timestamptz NOT NULL DEFAULT now(),
  offer_id       text,                        -- external offer ID for dedup

  CONSTRAINT deal_cache_unique
    UNIQUE (company_id, product_id, retailer, offer_id)
);

CREATE INDEX IF NOT EXISTS idx_deal_cache_company     ON public.deal_cache(company_id);
CREATE INDEX IF NOT EXISTS idx_deal_cache_product     ON public.deal_cache(product_id);
CREATE INDEX IF NOT EXISTS idx_deal_cache_valid_until ON public.deal_cache(valid_until);


-- ─── C. RLS policies ────────────────────────────────────────────────────────

ALTER TABLE public.deal_cache ENABLE ROW LEVEL SECURITY;

-- Read: any authenticated member of the company
CREATE POLICY "deal_cache_select"
  ON public.deal_cache
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());

-- Insert/Update/Delete: only the service role (edge function) writes
-- No authenticated-user write policy needed — the edge function uses
-- the service_role key which bypasses RLS.


-- ─── D. Cleanup function: remove expired deals ─────────────────────────────

CREATE OR REPLACE FUNCTION public.cleanup_expired_deals()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  deleted_count integer;
BEGIN
  DELETE FROM public.deal_cache
  WHERE valid_until < CURRENT_DATE - INTERVAL '1 day';
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;

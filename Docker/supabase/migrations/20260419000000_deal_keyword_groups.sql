-- =========================================================
-- Deal Keyword Groups
--
-- Hybrid matching layer on top of the existing product-name
-- fuzzy-match. Users define keyword groups on /deals with:
--   - optional display label
--   - one or more search terms (text[])
--   - a set of linked products (M:N)
--
-- One deal_cache row is written per (offer, keyword_group)
-- hit, so brand-wide offers (e.g. "Haribo versch. Sorten")
-- no longer duplicate across every catalog variant.
-- =========================================================


-- ─── A. deal_keywords (keyword groups) ─────────────────────

CREATE TABLE IF NOT EXISTS public.deal_keywords (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  uuid        NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  label       text        NULL,
  terms       text[]      NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT deal_keywords_terms_not_empty
    CHECK (array_length(terms, 1) >= 1)
);

CREATE INDEX IF NOT EXISTS idx_deal_keywords_company ON public.deal_keywords(company_id);

CREATE OR REPLACE FUNCTION public.tg_deal_keywords_set_updated_at()
  RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS deal_keywords_set_updated_at ON public.deal_keywords;
CREATE TRIGGER deal_keywords_set_updated_at
  BEFORE UPDATE ON public.deal_keywords
  FOR EACH ROW EXECUTE FUNCTION public.tg_deal_keywords_set_updated_at();

ALTER TABLE public.deal_keywords ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "deal_keywords_select" ON public.deal_keywords;
CREATE POLICY "deal_keywords_select" ON public.deal_keywords
  FOR SELECT TO authenticated
  USING (company_id = public.my_company_id());

DROP POLICY IF EXISTS "deal_keywords_insert" ON public.deal_keywords;
CREATE POLICY "deal_keywords_insert" ON public.deal_keywords
  FOR INSERT TO authenticated
  WITH CHECK (company_id = public.my_company_id());

DROP POLICY IF EXISTS "deal_keywords_update" ON public.deal_keywords;
CREATE POLICY "deal_keywords_update" ON public.deal_keywords
  FOR UPDATE TO authenticated
  USING (company_id = public.my_company_id())
  WITH CHECK (company_id = public.my_company_id());

DROP POLICY IF EXISTS "deal_keywords_delete" ON public.deal_keywords;
CREATE POLICY "deal_keywords_delete" ON public.deal_keywords
  FOR DELETE TO authenticated
  USING (company_id = public.my_company_id());


-- ─── B. deal_keyword_products (M:N join) ───────────────────

CREATE TABLE IF NOT EXISTS public.deal_keyword_products (
  keyword_id  uuid        NOT NULL REFERENCES public.deal_keywords(id) ON DELETE CASCADE,
  product_id  uuid        NOT NULL REFERENCES public.products(id)      ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (keyword_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_deal_keyword_products_product
  ON public.deal_keyword_products(product_id);

ALTER TABLE public.deal_keyword_products ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "deal_keyword_products_select" ON public.deal_keyword_products;
CREATE POLICY "deal_keyword_products_select" ON public.deal_keyword_products
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.deal_keywords k
    WHERE k.id = deal_keyword_products.keyword_id
      AND k.company_id = public.my_company_id()
  ));

DROP POLICY IF EXISTS "deal_keyword_products_insert" ON public.deal_keyword_products;
CREATE POLICY "deal_keyword_products_insert" ON public.deal_keyword_products
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.deal_keywords k
    WHERE k.id = deal_keyword_products.keyword_id
      AND k.company_id = public.my_company_id()
  ));

DROP POLICY IF EXISTS "deal_keyword_products_delete" ON public.deal_keyword_products;
CREATE POLICY "deal_keyword_products_delete" ON public.deal_keyword_products
  FOR DELETE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.deal_keywords k
    WHERE k.id = deal_keyword_products.keyword_id
      AND k.company_id = public.my_company_id()
  ));


-- ─── C. deal_cache extensions ──────────────────────────────

-- Drop the old single unique constraint; we replace it with two partial indexes below.
ALTER TABLE public.deal_cache DROP CONSTRAINT IF EXISTS deal_cache_unique;

-- New nullable columns for keyword-match rows.
ALTER TABLE public.deal_cache
  ADD COLUMN IF NOT EXISTS keyword_id   uuid NULL REFERENCES public.deal_keywords(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS matched_term text NULL;

-- product_id becomes nullable. DROP NOT NULL is idempotent (no-op if already nullable).
ALTER TABLE public.deal_cache ALTER COLUMN product_id DROP NOT NULL;

-- XOR: exactly one of product_id / keyword_id is set.
-- PostgreSQL has no "ADD CONSTRAINT IF NOT EXISTS" for CHECK, so DROP+ADD.
ALTER TABLE public.deal_cache DROP CONSTRAINT IF EXISTS deal_cache_product_xor_keyword;
ALTER TABLE public.deal_cache
  ADD CONSTRAINT deal_cache_product_xor_keyword
  CHECK ((product_id IS NOT NULL) <> (keyword_id IS NOT NULL));

-- Two partial unique indexes — back the two upsert conflict targets in the
-- edge function (split upsert pattern).
CREATE UNIQUE INDEX IF NOT EXISTS uq_deal_cache_product
  ON public.deal_cache (company_id, product_id, retailer, offer_id)
  WHERE product_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_deal_cache_keyword
  ON public.deal_cache (company_id, keyword_id, retailer, offer_id)
  WHERE keyword_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_deal_cache_keyword ON public.deal_cache(keyword_id);

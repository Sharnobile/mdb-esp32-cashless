-- Deal plausibility filter: an offer whose every matched product has an EK and
-- whose deal price (gross) exceeds the highest recorded EK gross for ALL of them
-- is a likely mismatch → suppressed. A product without EK, or with deal <= max EK,
-- keeps the offer visible. Centralized here; consumed by get_new_deal_keys and
-- the deal-search push. No-op when no EK rows exist (helper returns nothing).

-- get_suppressed_offer_keys ---------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_suppressed_offer_keys(p_company_id uuid)
RETURNS TABLE (retailer text, offer_id text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH rows AS (
    SELECT dc.id, dc.retailer, dc.offer_id, dc.deal_price, dc.product_id, dc.keyword_id
    FROM public.deal_cache dc
    WHERE dc.company_id = p_company_id AND dc.offer_id IS NOT NULL AND dc.deal_price IS NOT NULL
  ),
  resolved AS (   -- (row_id, deal_price, product_id) for rows resolving to >=1 product
    SELECT r.id AS row_id, r.deal_price, r.product_id AS rp
    FROM rows r WHERE r.product_id IS NOT NULL
    UNION ALL
    SELECT r.id AS row_id, r.deal_price, dkp.product_id AS rp
    FROM rows r
    JOIN public.deal_keyword_products dkp ON dkp.keyword_id = r.keyword_id
    WHERE r.keyword_id IS NOT NULL
  ),
  ek AS (
    SELECT product_id, max(price_gross) AS max_gross
    FROM public.product_purchase_prices
    WHERE company_id = p_company_id
    GROUP BY product_id
  ),
  row_product AS (
    SELECT res.row_id,
           (ek.max_gross IS NULL) AS no_ek,
           (ek.max_gross IS NOT NULL AND res.deal_price > ek.max_gross) AS implausible
    FROM resolved res
    LEFT JOIN ek ON ek.product_id = res.rp
  ),
  row_flag AS (
    SELECT r.id AS row_id, r.retailer, r.offer_id,
           ( EXISTS (SELECT 1 FROM row_product rp WHERE rp.row_id = r.id)
             AND NOT EXISTS (SELECT 1 FROM row_product rp WHERE rp.row_id = r.id AND rp.no_ek)
             AND NOT EXISTS (SELECT 1 FROM row_product rp WHERE rp.row_id = r.id AND NOT rp.implausible)
           ) AS row_implausible
    FROM rows r
  )
  SELECT retailer, offer_id
  FROM row_flag
  GROUP BY retailer, offer_id
  HAVING bool_and(row_implausible);
$$;

-- service_role (deal-search edge fn) needs to call it directly; the
-- get_new_deal_keys definer function calls it regardless of grant.
GRANT EXECUTE ON FUNCTION public.get_suppressed_offer_keys(uuid) TO service_role;

-- get_new_deal_keys: full original body + suppression exclusion ---------------
CREATE OR REPLACE FUNCTION public.get_new_deal_keys()
RETURNS TABLE (retailer text, offer_id text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_company  uuid := public.my_company_id();
  v_user     uuid := auth.uid();
  v_baseline timestamptz;
BEGIN
  IF v_company IS NULL OR v_user IS NULL THEN RETURN; END IF;

  INSERT INTO public.deal_user_seen (user_id, company_id)
  VALUES (v_user, v_company)
  ON CONFLICT (user_id, company_id) DO NOTHING;

  SELECT dus.baseline_at INTO v_baseline
  FROM public.deal_user_seen dus
  WHERE dus.user_id = v_user AND dus.company_id = v_company;

  RETURN QUERY
  SELECT DISTINCT dc.retailer, dc.offer_id
  FROM public.deal_cache dc
  JOIN public.deal_offer_first_seen fs
    ON  fs.company_id = dc.company_id
    AND fs.retailer   = dc.retailer
    AND fs.offer_id   = dc.offer_id
  WHERE dc.company_id = v_company
    AND dc.offer_id IS NOT NULL
    AND (dc.valid_until IS NULL OR dc.valid_until >= current_date)
    AND fs.first_seen_at > v_baseline
    AND NOT EXISTS (
      SELECT 1 FROM public.deal_user_state us
      WHERE us.user_id    = v_user
        AND us.company_id  = v_company
        AND us.retailer    = dc.retailer
        AND us.offer_id    = dc.offer_id
        AND (us.pinned_at IS NOT NULL OR us.archived_at IS NOT NULL)
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.get_suppressed_offer_keys(v_company) s
      WHERE s.retailer = dc.retailer AND s.offer_id = dc.offer_id
    );
END $$;

GRANT EXECUTE ON FUNCTION public.get_new_deal_keys() TO authenticated;

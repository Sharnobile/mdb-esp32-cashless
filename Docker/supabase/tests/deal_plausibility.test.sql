-- Tests get_suppressed_offer_keys + get_new_deal_keys suppression.
-- Rolled back. Plain ASSERTs. Fake JWT for the authenticated path.
BEGIN;
SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company uuid := gen_random_uuid();
  v_user    uuid := gen_random_uuid();
  v_class   uuid := gen_random_uuid();
  v_prod_a  uuid := gen_random_uuid();  -- has EK, deal far above max → suppress
  v_prod_b  uuid := gen_random_uuid();  -- has EK, deal below max → keep
  v_prod_c  uuid := gen_random_uuid();  -- no EK → keep
  v_sup     uuid := gen_random_uuid();
  n_supp    int;
BEGIN
  INSERT INTO public.companies (id, name, country_code) VALUES (v_company, 'EK Co', 'DE');
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'ek@test.local', now());
  INSERT INTO public.users (id, company, email) VALUES (v_user, v_company, 'ek@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role) VALUES (v_company, v_user, 'admin');

  INSERT INTO public.tax_classes (id, company_id, name) VALUES (v_class, v_company, 'LM');
  INSERT INTO public.tax_rates (company_id, tax_class_id, country_code, rate, name, valid_from)
    VALUES (v_company, v_class, 'DE', 0.0700, '7%', DATE '2020-01-01');
  INSERT INTO public.products (id, name, company, tax_class_id) VALUES (v_prod_a, 'A', v_company, v_class);
  INSERT INTO public.products (id, name, company, tax_class_id) VALUES (v_prod_b, 'B', v_company, v_class);
  INSERT INTO public.products (id, name, company, tax_class_id) VALUES (v_prod_c, 'C', v_company, v_class);
  INSERT INTO public.suppliers (id, company_id, name) VALUES (v_sup, v_company, 'S');

  -- EK gross: A max 0.54, B max 1.00 ; C none
  INSERT INTO public.product_purchase_prices (company_id, product_id, supplier_id, price_net, price_gross, price_basis, tax_rate, observed_on)
    VALUES (v_company, v_prod_a, v_sup, 0.50, 0.54, 'net', 0.07, DATE '2026-06-01');
  INSERT INTO public.product_purchase_prices (company_id, product_id, supplier_id, price_net, price_gross, price_basis, tax_rate, observed_on)
    VALUES (v_company, v_prod_b, v_sup, 0.93, 1.00, 'net', 0.07, DATE '2026-06-01');

  -- deal_cache: offer X1 (product A, deal 2.99 → above 0.54 → suppress),
  --             offer X2 (product B, deal 0.80 → below 1.00 → keep),
  --             offer X3 (product C, deal 5.00 → no EK → keep)
  INSERT INTO public.deal_cache (company_id, product_id, retailer, deal_title, deal_price, offer_id, matched_by, confidence)
    VALUES (v_company, v_prod_a, 'REWE', 'A premium', 2.99, 'X1', 'name_fuzzy', 0.6);
  INSERT INTO public.deal_cache (company_id, product_id, retailer, deal_title, deal_price, offer_id, matched_by, confidence)
    VALUES (v_company, v_prod_b, 'REWE', 'B', 0.80, 'X2', 'name_fuzzy', 0.9);
  INSERT INTO public.deal_cache (company_id, product_id, retailer, deal_title, deal_price, offer_id, matched_by, confidence)
    VALUES (v_company, v_prod_c, 'REWE', 'C', 5.00, 'X3', 'name_fuzzy', 0.9);

  -- Test 1: only X1 is suppressed
  SELECT count(*) INTO n_supp FROM public.get_suppressed_offer_keys(v_company);
  ASSERT n_supp = 1, format('expected 1 suppressed, got %s', n_supp);
  ASSERT EXISTS (SELECT 1 FROM public.get_suppressed_offer_keys(v_company) WHERE retailer='REWE' AND offer_id='X1'),
    'X1 suppressed';
  RAISE NOTICE 'Test 1 passed: only above-max-EK offer suppressed';

  -- Test 2: tie (deal exactly = max EK) is NOT suppressed
  UPDATE public.deal_cache SET deal_price = 0.54 WHERE offer_id = 'X1';
  ASSERT (SELECT count(*) FROM public.get_suppressed_offer_keys(v_company)) = 0,
    'tie (deal == max EK) not suppressed';
  RAISE NOTICE 'Test 2 passed: equality not suppressed';

  -- Test 3: get_new_deal_keys excludes suppressed (set X1 back above max)
  UPDATE public.deal_cache SET deal_price = 2.99 WHERE offer_id = 'X1';
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  -- first_seen rows so they qualify as "new" (baseline created lazily = now())
  INSERT INTO public.deal_offer_first_seen (company_id, retailer, offer_id, first_seen_at)
    VALUES (v_company, 'REWE', 'X1', now()), (v_company, 'REWE', 'X2', now()), (v_company, 'REWE', 'X3', now());
  -- baseline must predate first_seen → backdate it after lazy-create
  PERFORM public.get_new_deal_keys();
  UPDATE public.deal_user_seen SET baseline_at = now() - interval '1 day'
    WHERE user_id = v_user AND company_id = v_company;
  ASSERT NOT EXISTS (SELECT 1 FROM public.get_new_deal_keys() WHERE offer_id = 'X1'),
    'suppressed X1 excluded from new keys';
  ASSERT EXISTS (SELECT 1 FROM public.get_new_deal_keys() WHERE offer_id = 'X2'),
    'plausible X2 present in new keys';
  RAISE NOTICE 'Test 3 passed: get_new_deal_keys excludes suppressed';
END $$;

ROLLBACK;

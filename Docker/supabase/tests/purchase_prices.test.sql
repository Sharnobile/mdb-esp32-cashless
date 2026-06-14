-- Integration test for resolve_product_tax_rate / add_purchase_price /
-- update_purchase_price / get_product_purchase_summary.
-- Rolled back at the end → no dev data touched. Plain ASSERTs, no pgTAP.

BEGIN;
SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company   uuid := gen_random_uuid();
  v_other     uuid := gen_random_uuid();
  v_user      uuid := gen_random_uuid();
  v_user_o    uuid := gen_random_uuid();
  v_class     uuid := gen_random_uuid();
  v_cat       uuid := gen_random_uuid();
  v_product   uuid := gen_random_uuid();
  v_no_tax    uuid := gen_random_uuid();
  v_added     jsonb;
  v_rate      numeric;
  r           record;
BEGIN
  -- Companies + auth/users/members
  INSERT INTO public.companies (id, name, country_code) VALUES (v_company, 'EK Co', 'DE');
  INSERT INTO public.companies (id, name, country_code) VALUES (v_other, 'Other Co', 'DE');
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'ek@test.local', now());
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user_o, '00000000-0000-0000-0000-000000000000', 'o@test.local', now());
  INSERT INTO public.users (id, company, email) VALUES (v_user, v_company, 'ek@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.users (id, company, email) VALUES (v_user_o, v_other, 'o@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role) VALUES (v_company, v_user, 'admin');
  INSERT INTO public.organization_members (company_id, user_id, role) VALUES (v_other, v_user_o, 'admin');

  -- Tax class + 7% inclusive rate + category + product (category carries the class)
  INSERT INTO public.tax_classes (id, company_id, name) VALUES (v_class, v_company, 'Lebensmittel');
  INSERT INTO public.tax_rates (company_id, tax_class_id, country_code, rate, name, valid_from)
    VALUES (v_company, v_class, 'DE', 0.0700, '7%', DATE '2020-01-01');
  INSERT INTO public.product_category (id, name, company, tax_class_id) VALUES (v_cat, 'Snacks', v_company, v_class);
  INSERT INTO public.products (id, name, company, category, sellprice) VALUES (v_product, 'Snickers', v_company, v_cat, 1.20);
  INSERT INTO public.products (id, name, company, sellprice) VALUES (v_no_tax, 'NoTax', v_company, 0.99);

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- Test 1: resolve_product_tax_rate returns 0.07 for product, NULL for untaxed
  v_rate := public.resolve_product_tax_rate(v_product);
  ASSERT v_rate = 0.0700, format('expected 0.07, got %s', v_rate);
  v_rate := public.resolve_product_tax_rate(v_no_tax);
  ASSERT v_rate IS NULL, format('expected NULL rate for untaxed product, got %s', v_rate);
  RAISE NOTICE 'Test 1 passed: tax-rate resolution';

  -- Test 2: add net price → gross computed via 7%, supplier auto-created
  v_added := public.add_purchase_price(v_product, 'Großhandel Müller', 0.50, 'net', DATE '2026-06-01', NULL, NULL);
  ASSERT (v_added->>'price_gross')::numeric = 0.5350, format('expected gross 0.5350, got %s', v_added->>'price_gross');
  ASSERT (v_added->>'price_net')::numeric  = 0.5000, format('expected net 0.5000, got %s', v_added->>'price_net');
  ASSERT (v_added->>'supplier_name') = 'Großhandel Müller', 'supplier name echoed';
  ASSERT EXISTS (SELECT 1 FROM public.suppliers WHERE company_id = v_company AND name = 'Großhandel Müller'),
    'supplier auto-created';
  RAISE NOTICE 'Test 2 passed: add net, gross computed, supplier created';

  -- Test 3: add gross price for a different (cheaper) supplier, case-insensitive reuse
  PERFORM public.add_purchase_price(v_product, 'metro', 0.5136, 'gross', DATE '2026-03-01', NULL, NULL);
  PERFORM public.add_purchase_price(v_product, 'METRO', 0.55,   'gross', DATE '2026-02-01', NULL, NULL);
  ASSERT (SELECT count(*) FROM public.suppliers WHERE company_id = v_company AND lower(name) = 'metro') = 1,
    'metro deduplicated case-insensitively';

  -- Test 4: summary aggregates (newest = Müller 06-01, min_gross = metro 0.5136)
  SELECT * INTO r FROM public.get_product_purchase_summary(ARRAY[v_product]);
  ASSERT r.ek_count = 3, format('expected ek_count 3, got %s', r.ek_count);
  ASSERT r.newest_gross = 0.5350, format('expected newest_gross 0.5350, got %s', r.newest_gross);
  ASSERT r.newest_supplier = 'Großhandel Müller', 'newest supplier is Müller';
  ASSERT r.min_gross = 0.5136, format('expected min_gross 0.5136, got %s', r.min_gross);
  ASSERT r.max_gross = 0.5500, format('expected max_gross 0.5500, got %s', r.max_gross);
  ASSERT r.effective_tax_rate = 0.0700, 'effective rate echoed';
  RAISE NOTICE 'Test 4 passed: summary aggregation';

  -- Test 5: untaxed product needs an override, else tax_rate_required
  BEGIN
    PERFORM public.add_purchase_price(v_no_tax, 'Müller', 1.00, 'net', CURRENT_DATE, NULL, NULL);
    RAISE EXCEPTION 'Test 5 FAILED: expected tax_rate_required';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE '%tax_rate_required%', format('Test 5 wrong error: %s', SQLERRM);
  END;
  v_added := public.add_purchase_price(v_no_tax, 'Müller', 1.00, 'net', CURRENT_DATE, NULL, 0.1900);
  ASSERT (v_added->>'price_gross')::numeric = 1.1900, format('expected 1.19 with override, got %s', v_added->>'price_gross');
  RAISE NOTICE 'Test 5 passed: tax override path';

  -- Test 6: other company cannot add a price to v_product
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_o::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.add_purchase_price(v_product, 'X', 1.0, 'net', CURRENT_DATE, NULL, 0.19);
    RAISE EXCEPTION 'Test 6 FAILED: cross-company add not rejected';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE '%not found or access denied%', format('Test 6 wrong error: %s', SQLERRM);
  END;
  -- summary for other company returns the product row with ek_count 0 only if owned;
  -- here v_product is not owned → no row returned.
  ASSERT NOT EXISTS (SELECT 1 FROM public.get_product_purchase_summary(ARRAY[v_product])),
    'other company sees no summary row for foreign product';
  RAISE NOTICE 'Test 6 passed: cross-company isolation';
END $$;

ROLLBACK;

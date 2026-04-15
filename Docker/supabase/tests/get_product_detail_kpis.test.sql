-- Integration test for get_product_detail_kpis.
-- Runs inside one transaction that is rolled back at the end → no dev data touched.
-- Uses plain ASSERT statements inside a DO block (no pgTAP required).
-- Fake JWT is injected via set_config('request.jwt.claims', ..., true) so
-- SECURITY DEFINER + my_company_id() can be tested without real auth.

BEGIN;

-- Pin a stable "now" so today-window assertions are deterministic
SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company_a uuid := gen_random_uuid();
  v_company_b uuid := gen_random_uuid();
  v_user_a    uuid := gen_random_uuid();
  v_user_b    uuid := gen_random_uuid();
  v_product   uuid := gen_random_uuid();
  v_machine   uuid := gen_random_uuid();
  v_warehouse uuid := gen_random_uuid();
  v_kpis      jsonb;
  v_top_units bigint;
BEGIN
  -- ─── Seed companies ───────────────────────────────────────────────────────
  INSERT INTO public.companies (id, name, velocity_days)
    VALUES (v_company_a, 'TestCo A', 7);
  INSERT INTO public.companies (id, name, velocity_days)
    VALUES (v_company_b, 'TestCo B', 7);

  -- ─── Auth users + public.users + organization_members ────────────────────
  -- Note: on_auth_user_created trigger copies (id, created_at, email) into
  -- public.users, so created_at must be set here to avoid a NOT NULL violation.
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user_a, '00000000-0000-0000-0000-000000000000', 'a@test.local', now());
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user_b, '00000000-0000-0000-0000-000000000000', 'b@test.local', now());

  -- public.users may already exist from the on_auth_user_created trigger.
  -- Update company linkage instead of inserting.
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_a, v_company_a, 'a@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company, email = EXCLUDED.email;
  INSERT INTO public.users (id, company, email)
    VALUES (v_user_b, v_company_b, 'b@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company, email = EXCLUDED.email;

  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company_a, v_user_a, 'admin');
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company_b, v_user_b, 'admin');

  -- ─── Product, machine, warehouse, tray, batch, sales ─────────────────────
  INSERT INTO public.products (id, name, company)
    VALUES (v_product, 'Test Coke', v_company_a);
  INSERT INTO public."vendingMachine" (id, name, company)
    VALUES (v_machine, 'Test Machine', v_company_a);
  INSERT INTO public.warehouses (id, name, company_id)
    VALUES (v_warehouse, 'Test WH', v_company_a);
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock)
    VALUES (v_machine, 1, v_product, 10, 7);
  INSERT INTO public.warehouse_stock_batches
    (warehouse_id, product_id, quantity, company_id)
    VALUES (v_warehouse, v_product, 25, v_company_a);

  -- Two sales: one today, one 5 days ago.
  -- Note: the on_sale_stamp_machine_and_decrement_stock BEFORE-INSERT trigger
  -- (a) stamps sales.product_id from the matching tray, and (b) decrements
  -- tray.current_stock by 1. After both INSERTs, current_stock drops from 7 → 5.
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
    VALUES (v_machine, 1, 2.50, 'cashless', now());
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
    VALUES (v_machine, 1, 2.50, 'cashless', now() - interval '5 days');

  -- ─── Test 1: caller from company A sees correct KPIs ─────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text,
    true);

  SELECT public.get_product_detail_kpis(v_product, 30) INTO v_kpis;

  ASSERT (v_kpis->>'warehouse_total_qty')::bigint = 25,
    format('expected warehouse_total_qty=25, got %s', v_kpis->>'warehouse_total_qty');
  -- Tray started at current_stock=7; two sales decremented it to 5.
  ASSERT (v_kpis->>'tray_total_stock')::bigint = 5,
    format('expected tray_total_stock=5 (7 minus 2 sales), got %s', v_kpis->>'tray_total_stock');
  ASSERT (v_kpis->>'tray_total_capacity')::bigint = 10,
    format('expected tray_total_capacity=10, got %s', v_kpis->>'tray_total_capacity');
  ASSERT (v_kpis->>'machine_count')::int = 1,
    format('expected machine_count=1, got %s', v_kpis->>'machine_count');
  ASSERT (v_kpis->>'warehouse_count')::int = 1,
    format('expected warehouse_count=1, got %s', v_kpis->>'warehouse_count');
  ASSERT (v_kpis->>'sales_today_units')::bigint = 1,
    format('expected sales_today_units=1, got %s', v_kpis->>'sales_today_units');
  ASSERT (v_kpis->>'sales_7d_units')::bigint = 2,
    format('expected sales_7d_units=2, got %s', v_kpis->>'sales_7d_units');

  -- top_machines is a jsonb array; first element has units=2, name='Test Machine'
  SELECT (v_kpis->'top_machines'->0->>'units')::bigint INTO v_top_units;
  ASSERT v_top_units = 2,
    format('expected top_machines[0].units=2, got %s', v_top_units);
  ASSERT v_kpis->'top_machines'->0->>'machine_name' = 'Test Machine',
    'expected top_machines[0].machine_name=Test Machine';

  RAISE NOTICE 'Test 1 passed: KPIs for own-company product';

  -- ─── Test 2: caller from company B is blocked ────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_b::text, 'role', 'authenticated')::text,
    true);

  BEGIN
    PERFORM public.get_product_detail_kpis(v_product, 30);
    RAISE EXCEPTION 'Test 2 FAILED: expected exception was not raised';
  EXCEPTION
    WHEN OTHERS THEN
      ASSERT SQLERRM LIKE '%product not found or access denied%',
        format('Test 2 FAILED: wrong error message: %s', SQLERRM);
      RAISE NOTICE 'Test 2 passed: cross-company call rejected with: %', SQLERRM;
  END;

END $$;

ROLLBACK;

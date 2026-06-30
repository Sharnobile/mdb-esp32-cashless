-- Tests is_platform_admin gating + get_platform_overview / _company_detail.
-- Rolled back. Plain ASSERTs. Fake JWT for the authenticated path.
BEGIN;
SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company  uuid := gen_random_uuid();
  v_admin    uuid := gen_random_uuid();  -- platform admin
  v_other    uuid := gen_random_uuid();  -- normal user, NOT platform admin
  v_dev      uuid := gen_random_uuid();
  v_overview json;
  v_detail   json;
  v_raised   boolean := false;
BEGIN
  -- Fixtures
  INSERT INTO public.companies (id, name) VALUES (v_company, 'Acme');
  INSERT INTO auth.users (id, instance_id, email, created_at) VALUES
    (v_admin, '00000000-0000-0000-0000-000000000000', 'admin@test.local', now()),
    (v_other, '00000000-0000-0000-0000-000000000000', 'other@test.local', now());
  INSERT INTO public.users (id, company, email) VALUES
    (v_admin, v_company, 'admin@test.local'),
    (v_other, v_company, 'other@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role) VALUES
    (v_company, v_admin, 'admin'),
    (v_company, v_other, 'viewer');
  INSERT INTO public.embeddeds (id, company, status, status_at) VALUES
    (v_dev, v_company, 'online', now());
  INSERT INTO public."vendingMachine" (name, company, embedded) VALUES ('M1', v_company, v_dev);
  INSERT INTO public.sales (embedded_id, item_price, item_number, channel, created_at)
    VALUES (v_dev, 2.50, 11, 'mdb', now());

  -- Grant platform admin to v_admin only
  INSERT INTO public.platform_admins (user_id) VALUES (v_admin);

  -- Test 1: non-platform-admin is rejected
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_other)::text, true);
  BEGIN
    PERFORM public.get_platform_overview(30);
  EXCEPTION WHEN insufficient_privilege THEN  -- the function's errcode 42501
    v_raised := true;
  END;
  ASSERT v_raised, 'non-platform-admin must be rejected by get_platform_overview';
  RAISE NOTICE 'Test 1 passed: non-admin rejected';

  -- Test 2: is_platform_admin reflects membership
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  ASSERT public.is_platform_admin() = true,  'admin recognised';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_other)::text, true);
  ASSERT public.is_platform_admin() = false, 'non-admin not recognised';
  RAISE NOTICE 'Test 2 passed: is_platform_admin correct';

  -- Test 3: overview returns totals + the company row (as platform admin)
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  v_overview := public.get_platform_overview(30);
  ASSERT (v_overview->'totals'->>'company_count')::int >= 1,  'company_count >= 1';
  ASSERT (v_overview->'totals'->>'devices_online')::int >= 1, 'devices_online >= 1';
  ASSERT EXISTS (
    SELECT 1 FROM json_array_elements(v_overview->'companies') x
    WHERE (x->>'company_id') = v_company::text
      AND (x->>'user_count')::int = 2
      AND (x->>'machine_count')::int = 1
      AND (x->>'devices_online')::int = 1
      AND (x->>'sales_today_count')::int = 1
      AND (x->>'sales_today_revenue')::numeric = 2.50
  ), 'company row has correct aggregates';
  RAISE NOTICE 'Test 3 passed: overview aggregates correct';

  -- Test 4: drill-down returns members + devices + sales
  v_detail := public.get_platform_company_detail(v_company);
  ASSERT json_array_length(v_detail->'members') = 2,       'detail has 2 members';
  ASSERT json_array_length(v_detail->'devices') = 1,       'detail has 1 device';
  ASSERT json_array_length(v_detail->'recent_sales') = 1,  'detail has 1 recent sale';
  RAISE NOTICE 'Test 4 passed: company detail correct';

  RAISE NOTICE 'ALL platform_admin tests passed';
END $$;

ROLLBACK;

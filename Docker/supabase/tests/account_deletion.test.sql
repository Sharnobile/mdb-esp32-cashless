-- Account deletion: FK rewiring + delete_company_and_data.
-- Rolled back. Plain ASSERTs. See spec 2026-07-15-ios-app-store-release §4.
BEGIN;
SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company   uuid := gen_random_uuid();
  v_company2  uuid := gen_random_uuid();
  v_admin     uuid := gen_random_uuid();
  v_admin2    uuid := gen_random_uuid();
  v_viewer    uuid := gen_random_uuid();
  v_dev       uuid := gen_random_uuid();
  v_dev2      uuid := gen_random_uuid();
  v_machine   uuid;
  v_machine2  uuid;
  v_book      uuid := gen_random_uuid();
  v_devices   uuid[];
  v_machines  uuid[];
  n           int;
BEGIN
  -- ── Fixtures: company 1, two admins, a device, a machine, real data ──
  INSERT INTO public.companies (id, name) VALUES (v_company, 'Acme');
  INSERT INTO auth.users (id, instance_id, email, created_at) VALUES
    (v_admin,  '00000000-0000-0000-0000-000000000000', 'admin@test.local',  now()),
    (v_admin2, '00000000-0000-0000-0000-000000000000', 'admin2@test.local', now());
  INSERT INTO public.users (id, company, email) VALUES
    (v_admin,  v_company, 'admin@test.local'),
    (v_admin2, v_company, 'admin2@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role) VALUES
    (v_company, v_admin,  'admin'),
    (v_company, v_admin2, 'admin');

  INSERT INTO public.embeddeds (id, company, owner_id, status, status_at)
    VALUES (v_dev, v_company, v_admin, 'online', now());
  INSERT INTO public."vendingMachine" (name, company, embedded)
    VALUES ('M1', v_company, v_dev) RETURNING id INTO v_machine;

  INSERT INTO public.sales (embedded_id, machine_id, owner_id, item_price, item_number, channel, created_at)
    VALUES (v_dev, v_machine, v_admin, 2.50, 11, 'mdb', now());
  INSERT INTO public.paxcounter (embedded_id, machine_id, owner_id, count)
    VALUES (v_dev, v_machine, v_admin, 7);
  INSERT INTO public.stock_decrement_log (embedded_id, machine_id, item_number, item_price, reason)
    VALUES (v_dev, v_machine, 11, 2.50, 'test');
  INSERT INTO public.api_keys (company_id, key_hash, key_prefix, name, created_by)
    VALUES (v_company, 'hash', 'pfx', 'k', v_admin);
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by)
    VALUES (v_book, v_company, 'Kasse', 0, v_admin);

  -- ── Test 1: a realistic admin can be deleted (second admin present) ──
  -- Before the FK migration this raised 23503 via sales.owner_id.
  DELETE FROM auth.users WHERE id = v_admin;
  ASSERT NOT EXISTS (SELECT 1 FROM auth.users WHERE id = v_admin),
    'realistic admin must be deletable';
  ASSERT EXISTS (SELECT 1 FROM public.sales WHERE embedded_id = v_dev AND owner_id IS NULL),
    'sales must survive the owner with owner_id nulled';
  ASSERT EXISTS (SELECT 1 FROM public.api_keys WHERE company_id = v_company AND created_by IS NULL),
    'api key must survive its creator';
  ASSERT EXISTS (SELECT 1 FROM public.cash_book_entries WHERE company_id = v_company),
    'cash-book entries must survive their creator';
  RAISE NOTICE 'Test 1 passed: realistic user delete';

  -- ── Test 2: device delete keeps sales (device-swap regression) ──
  INSERT INTO public.embeddeds (id, company, status, status_at)
    VALUES (v_dev2, v_company, 'online', now());
  INSERT INTO public."vendingMachine" (name, company, embedded)
    VALUES ('M2', v_company, v_dev2) RETURNING id INTO v_machine2;
  INSERT INTO public.sales (embedded_id, machine_id, item_price, item_number, channel, created_at)
    VALUES (v_dev2, v_machine2, 1.50, 12, 'mdb', now());

  DELETE FROM public.embeddeds WHERE id = v_dev2;
  ASSERT EXISTS (
    SELECT 1 FROM public.sales
     WHERE machine_id = v_machine2 AND embedded_id IS NULL AND item_number = 12
  ), 'device delete must keep sales with machine_id set (20260301400000 behaviour)';
  RAISE NOTICE 'Test 2 passed: device-swap history preserved';

  -- ── Test 3: cascade completeness ──
  -- Snapshot ids BEFORE deleting; afterwards nothing remains to join on.
  SELECT coalesce(array_agg(id), '{}') INTO v_devices
    FROM public.embeddeds WHERE company = v_company;
  SELECT coalesce(array_agg(id), '{}') INTO v_machines
    FROM public."vendingMachine" WHERE company = v_company;

  PERFORM public.delete_company_and_data(v_company);

  ASSERT NOT EXISTS (SELECT 1 FROM public.companies WHERE id = v_company),
    'company row must be gone';

  SELECT count(*) INTO n FROM public.sales
   WHERE embedded_id = ANY(v_devices) OR machine_id = ANY(v_machines);
  ASSERT n = 0, format('%s orphaned sales rows remain', n);

  SELECT count(*) INTO n FROM public.paxcounter
   WHERE embedded_id = ANY(v_devices) OR machine_id = ANY(v_machines);
  ASSERT n = 0, format('%s orphaned paxcounter rows remain', n);

  SELECT count(*) INTO n FROM public.stock_decrement_log
   WHERE embedded_id = ANY(v_devices) OR machine_id = ANY(v_machines);
  ASSERT n = 0, format('%s orphaned stock_decrement_log rows remain', n);

  ASSERT NOT EXISTS (SELECT 1 FROM public.embeddeds WHERE id = ANY(v_devices)),
    'devices must cascade';
  ASSERT NOT EXISTS (SELECT 1 FROM public.cash_book_entries WHERE company_id = v_company),
    'cash-book entries must be erased by delete_company_and_data (explicit delete, not cascade)';
  RAISE NOTICE 'Test 3 passed: cascade completeness';

  -- ── Test 4: profile survival ──
  INSERT INTO public.companies (id, name) VALUES (v_company2, 'Beta');
  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_viewer, '00000000-0000-0000-0000-000000000000', 'viewer@test.local', now());
  INSERT INTO public.users (id, company, email) VALUES (v_viewer, v_company2, 'viewer@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company2, v_viewer, 'viewer');

  PERFORM public.delete_company_and_data(v_company2);

  ASSERT EXISTS (SELECT 1 FROM auth.users WHERE id = v_viewer),
    'a viewer of a deleted company must keep their auth account';
  ASSERT EXISTS (SELECT 1 FROM public.users WHERE id = v_viewer AND company IS NULL),
    'a viewer of a deleted company must keep their profile, with company nulled';
  RAISE NOTICE 'Test 4 passed: profile survival';
END $$;

-- ── Test 5: grants — the suite runs as postgres (superuser), which would mask
-- a missing service_role grant entirely. Check the ACL itself, per role.
DO $$
BEGIN
  ASSERT has_function_privilege('service_role',
    'public.delete_company_and_data(uuid)', 'EXECUTE'),
    'service_role must be able to execute delete_company_and_data';
  ASSERT NOT has_function_privilege('authenticated',
    'public.delete_company_and_data(uuid)', 'EXECUTE'),
    'authenticated must NOT be able to execute delete_company_and_data';
  ASSERT NOT has_function_privilege('anon',
    'public.delete_company_and_data(uuid)', 'EXECUTE'),
    'anon must NOT be able to execute delete_company_and_data';
  RAISE NOTICE 'Test 5 passed: grants';
  RAISE NOTICE 'All account-deletion tests passed';
END $$;

ROLLBACK;

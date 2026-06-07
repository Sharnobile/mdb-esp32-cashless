-- Integration test for restore_suppressed_sale
-- (migration 20260607000000_restore_suppressed_sale.sql).
--
-- Runs inside one transaction, rolled back at the end → no dev data touched.
-- Plain ASSERTs in a DO block (no pgTAP). Fake JWT via set_config so the
-- SECURITY DEFINER i_am_admin()/my_company_id() checks are exercised.
--
-- Requires `supabase start` + `supabase --workdir Docker migration up`.
-- Run via Docker/supabase/tests/run-sql-tests.sh.
--
-- Scenarios:
--   Happy: admin restores a suppressed row → a real sale exists carrying the
--          SNAPSHOT product (not the current tray product), tray stock −1,
--          suppressed row gone, activity_log 'sale_restored' with
--          metadata.source='suppressed_restore', sale_seq + time_uncertain
--          preserved.
--   Neg 1: missing id                     → raises.
--   Neg 2: caller is a viewer (not admin) → raises (admin gate).
--   Neg 3: row belongs to another company → raises (ownership gate).

BEGIN;

SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company   uuid := gen_random_uuid();   -- company A
  v_companyB  uuid := gen_random_uuid();   -- company B (cross-company)
  v_admin     uuid := gen_random_uuid();   -- admin @ A
  v_viewer    uuid := gen_random_uuid();   -- viewer @ A
  v_embedded  uuid := gen_random_uuid();   -- device @ A
  v_embeddedB uuid := gen_random_uuid();   -- device @ B
  v_machine   uuid := gen_random_uuid();
  v_p_tray    uuid := gen_random_uuid();   -- product currently in the tray
  v_p_snap    uuid := gen_random_uuid();   -- product snapshot on the suppressed row
  v_sup1      uuid;   -- happy-path suppressed row
  v_sup2      uuid;   -- viewer-negative suppressed row
  v_sup3      uuid;   -- cross-company suppressed row
  v_sup4      uuid;   -- duplicate-seq suppressed row
  v_stock     integer;
  v_count     integer;
  v_sale      RECORD;
  r           jsonb;
BEGIN
  -- ─── Companies, users, memberships ───────────────────────────────────────
  INSERT INTO public.companies (id, name) VALUES (v_company, 'RestoreCoA'), (v_companyB, 'RestoreCoB');

  INSERT INTO auth.users (id, instance_id, email, created_at) VALUES
    (v_admin,  '00000000-0000-0000-0000-000000000000', 'admin@restore.local',  now()),
    (v_viewer, '00000000-0000-0000-0000-000000000000', 'viewer@restore.local', now());
  INSERT INTO public.users (id, company, email) VALUES
    (v_admin,  v_company, 'admin@restore.local'),
    (v_viewer, v_company, 'viewer@restore.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company, email = EXCLUDED.email;
  INSERT INTO public.organization_members (company_id, user_id, role) VALUES
    (v_company, v_admin,  'admin'),
    (v_company, v_viewer, 'viewer');

  -- ─── Devices, machine, products, tray (stock 5) ──────────────────────────
  INSERT INTO public.embeddeds (id, company, owner_id) VALUES
    (v_embedded,  v_company,  v_admin),
    (v_embeddedB, v_companyB, NULL);
  INSERT INTO public."vendingMachine" (id, name, company, embedded)
    VALUES (v_machine, 'M', v_company, v_embedded);
  INSERT INTO public.products (id, name, company) VALUES
    (v_p_tray, 'TrayProduct', v_company),
    (v_p_snap, 'SnapshotProduct', v_company);
  -- Current tray holds v_p_tray; suppressed snapshot is v_p_snap (different)
  -- so the test proves the RPC's product_id override beats the trigger.
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock)
    VALUES (v_machine, 1, v_p_tray, 10, 5);

  -- ─── Suppressed rows ─────────────────────────────────────────────────────
  INSERT INTO public.suppressed_sales
    (embedded_id, item_number, item_price, channel, sale_seq, device_created_at, received_at, reason, product_id)
    VALUES (v_embedded, 1, 1.50, 'cash', 42, '2026-06-05 10:00+00', '2026-06-05 10:00:03+00',
            'time_uncertain_duplicate', v_p_snap)
    RETURNING id INTO v_sup1;
  INSERT INTO public.suppressed_sales
    (embedded_id, item_number, item_price, channel, sale_seq, device_created_at, received_at, reason, product_id)
    VALUES (v_embedded, 1, 1.50, 'cash', 43, '2026-06-05 10:01+00', '2026-06-05 10:01:03+00',
            'time_uncertain_duplicate', v_p_snap)
    RETURNING id INTO v_sup2;
  INSERT INTO public.suppressed_sales
    (embedded_id, item_number, item_price, channel, sale_seq, device_created_at, received_at, reason, product_id)
    VALUES (v_embeddedB, 1, 1.50, 'cash', 99, '2026-06-05 10:02+00', '2026-06-05 10:02:03+00',
            'time_uncertain_duplicate', NULL)
    RETURNING id INTO v_sup3;

  -- ═══ Authenticate as admin @ A ═══════════════════════════════════════════
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  -- ═══ Happy path ══════════════════════════════════════════════════════════
  r := public.restore_suppressed_sale(v_sup1);
  RAISE NOTICE 'restore result: %', r;

  -- Suppressed row gone
  SELECT count(*) INTO v_count FROM public.suppressed_sales WHERE id = v_sup1;
  ASSERT v_count = 0, format('suppressed row should be deleted, found %s', v_count);

  -- A real sale exists, carries the SNAPSHOT product, seq + time_uncertain preserved
  SELECT id, product_id, sale_seq, time_uncertain, item_price, item_number, channel, machine_id
    INTO v_sale FROM public.sales WHERE id = (r->>'id')::uuid;
  ASSERT v_sale.product_id = v_p_snap,
    format('restored sale must carry the snapshot product %s, got %s', v_p_snap, v_sale.product_id);
  ASSERT v_sale.sale_seq = 42, format('sale_seq should be preserved (42), got %s', v_sale.sale_seq);
  ASSERT v_sale.time_uncertain = true, 'time_uncertain should be true';
  ASSERT v_sale.machine_id = v_machine, format('machine_id should resolve to %s, got %s', v_machine, v_sale.machine_id);
  ASSERT v_sale.item_price = 1.50, format('item_price should be 1.50, got %s', v_sale.item_price);

  -- Tray stock decremented by 1 (5 → 4)
  SELECT current_stock INTO v_stock FROM public.machine_trays WHERE machine_id = v_machine AND item_number = 1;
  ASSERT v_stock = 4, format('tray stock should be 4 after restore, got %s', v_stock);

  -- Returned jsonb must agree with the DB (the RPC keeps v_new.product_id in
  -- sync with the post-insert override; a regression dropping that would break
  -- the value the frontend consumes).
  ASSERT (r->>'product_id')::uuid = v_p_snap,
    format('returned jsonb product_id should be the snapshot %s, got %s', v_p_snap, r->>'product_id');

  -- Audit row written with metadata.source (NOT a source column) + attributed
  -- to the acting admin via the activity_log user_id DEFAULT auth.uid().
  SELECT count(*) INTO v_count FROM public.activity_log
   WHERE action = 'sale_restored'
     AND entity_id = v_sale.id::text
     AND metadata->>'source' = 'suppressed_restore';
  ASSERT v_count = 1, format('expected 1 sale_restored audit row, got %s', v_count);
  ASSERT (SELECT user_id FROM public.activity_log
            WHERE action = 'sale_restored' AND entity_id = v_sale.id::text) = v_admin,
    'audit user_id should be the acting admin';

  RAISE NOTICE 'Happy path passed';

  -- ═══ Neg 1: missing id raises ════════════════════════════════════════════
  BEGIN
    PERFORM public.restore_suppressed_sale(gen_random_uuid());
    ASSERT false, 'expected exception for missing id';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Neg 1 passed: missing id rejected (%)', SQLERRM;
  END;

  -- ═══ Neg 2: viewer (non-admin) raises ════════════════════════════════════
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_viewer::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.restore_suppressed_sale(v_sup2);
    ASSERT false, 'expected exception for non-admin caller';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Neg 2 passed: viewer rejected (%)', SQLERRM;
  END;
  -- v_sup2 must still exist (the failed call rolled back)
  SELECT count(*) INTO v_count FROM public.suppressed_sales WHERE id = v_sup2;
  ASSERT v_count = 1, 'viewer-rejected suppressed row must remain';

  -- ═══ Neg 3: cross-company raises ═════════════════════════════════════════
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.restore_suppressed_sale(v_sup3);  -- device belongs to company B
    ASSERT false, 'expected exception for cross-company row';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Neg 3 passed: cross-company rejected (%)', SQLERRM;
  END;

  -- ═══ Neg 4: duplicate (embedded_id, sale_seq) → friendly error ═══════════
  -- A real sale already occupies seq 77 for device A; a suppressed row with
  -- the same seq must fail to restore (not silently duplicate).
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
  INSERT INTO public.sales (embedded_id, item_number, item_price, channel, created_at, sale_seq)
    VALUES (v_embedded, 1, 1.50, 'cash', '2026-06-05 12:00+00', 77);
  INSERT INTO public.suppressed_sales
    (embedded_id, item_number, item_price, channel, sale_seq, device_created_at, received_at, reason, product_id)
    VALUES (v_embedded, 1, 1.50, 'cash', 77, '2026-06-05 12:00+00', '2026-06-05 12:00:03+00',
            'time_uncertain_duplicate', v_p_snap)
    RETURNING id INTO v_sup4;
  BEGIN
    PERFORM public.restore_suppressed_sale(v_sup4);
    ASSERT false, 'expected exception for duplicate sale_seq';
  EXCEPTION WHEN OTHERS THEN
    ASSERT SQLERRM LIKE '%already recorded%',
      format('expected friendly seq-collision error, got: %s', SQLERRM);
    RAISE NOTICE 'Neg 4 passed: duplicate seq rejected with friendly error (%)', SQLERRM;
  END;

  RAISE NOTICE 'All restore_suppressed_sale tests passed';
END $$;

ROLLBACK;

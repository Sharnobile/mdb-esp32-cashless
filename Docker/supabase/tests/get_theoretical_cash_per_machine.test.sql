-- Integration test for get_theoretical_cash per-machine anchoring
-- (migration 20260606000000_cash_book_per_machine_theoretical.sql).
--
-- Runs inside one transaction that is rolled back at the end → no dev data touched.
-- Uses plain ASSERT statements inside a DO block (no pgTAP required).
-- Fake JWT is injected via set_config('request.jwt.claims', ..., true) so the
-- SECURITY DEFINER function's auth.uid() membership check can be exercised.
--
-- Requires `supabase start` + the migration applied (`supabase migration up`).
-- Run via Docker/supabase/tests/run-sql-tests.sh.
--
-- Scenario: Barkasse X (track_per_machine ON) with machines A and B.
--   T0  initial entry (balance 0)
--       A cash 1.50 + 2.00  |  B cash 1.00 + 3.00   (before any collection)
--   T1  withdrawal collecting ONLY A (amount 3.50)
--       A cash 0.50 + card 5.00 (card excluded)  |  B cash 4.00
--   T2  bank deposit / payout 2.00 (machine_id NULL)
--
-- Per-machine ON:  A counts cash since ITS withdrawal (T1) = 0.50;
--                  B counts cash since the initial entry (T0) = 8.00 — A's
--                  withdrawal must NOT anchor B, and the payout must NOT anchor
--                  either. cash_sales_since = 8.50.
-- Per-machine OFF: every machine shares the last entry (the payout @ T2), so
--                  both read 0.00 — the pre-fix whole-Barkasse behaviour.

BEGIN;

SET LOCAL TIMEZONE = 'UTC';

DO $$
DECLARE
  v_company   uuid := gen_random_uuid();
  v_user      uuid := gen_random_uuid();
  v_stranger  uuid := gen_random_uuid();
  v_book      uuid := gen_random_uuid();
  v_machine_a uuid := gen_random_uuid();
  v_machine_b uuid := gen_random_uuid();
  v_product   uuid := gen_random_uuid();
  v_initial   uuid;
  r jsonb; a float8; b float8;
BEGIN
  -- ─── Company, auth user, membership ──────────────────────────────────────
  INSERT INTO public.companies (id, name) VALUES (v_company, 'CashTestCo');

  INSERT INTO auth.users (id, instance_id, email, created_at)
    VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'cash@test.local', now());
  INSERT INTO public.users (id, company, email)
    VALUES (v_user, v_company, 'cash@test.local')
    ON CONFLICT (id) DO UPDATE SET company = EXCLUDED.company, email = EXCLUDED.email;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (v_company, v_user, 'admin');

  -- ─── Barkasse (per-machine ON) + machines assigned to it ─────────────────
  -- Inserting the Barkasse auto-creates its 'initial' entry via the
  -- after_insert trigger; we pin that entry's created_at to T0 below.
  INSERT INTO public.cash_books (id, company_id, name, initial_balance, created_by, track_per_machine)
    VALUES (v_book, v_company, 'X', 0, v_user, true);

  UPDATE public.cash_book_entries
     SET created_at = '2026-06-01 08:00+00'
   WHERE cash_book_id = v_book AND type = 'initial'
   RETURNING id INTO v_initial;

  INSERT INTO public."vendingMachine" (id, name, company, cash_book_id) VALUES
    (v_machine_a, 'A', v_company, v_book),
    (v_machine_b, 'B', v_company, v_book);

  -- Trays so the sales stamp/decrement trigger has a target (stock irrelevant here).
  INSERT INTO public.products (id, name, company) VALUES (v_product, 'TestBar', v_company);
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock) VALUES
    (v_machine_a, 1, v_product, 100, 100),
    (v_machine_b, 1, v_product, 100, 100);

  -- ─── Sales before A's collection (T0 → T1) ───────────────────────────────
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at) VALUES
    (v_machine_a, 1, 1.50, 'cash', '2026-06-01 09:00+00'),
    (v_machine_a, 1, 2.00, 'cash', '2026-06-01 10:00+00'),
    (v_machine_b, 1, 1.00, 'cash', '2026-06-01 09:30+00'),
    (v_machine_b, 1, 3.00, 'cash', '2026-06-01 11:00+00');

  -- ─── Withdrawal collecting ONLY machine A @ T1 (entry_number/balance auto) ─
  INSERT INTO public.cash_book_entries
    (created_at, cash_book_id, company_id, type, amount, machine_id, created_by)
    VALUES ('2026-06-02 08:00+00', v_book, v_company, 'withdrawal', 3.50, v_machine_a, v_user);

  -- ─── Sales after T1 (A cash 0.50 + card 5.00 excluded; B cash 4.00) ───────
  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at) VALUES
    (v_machine_a, 1, 0.50, 'cash', '2026-06-02 09:00+00'),
    (v_machine_a, 1, 5.00, 'card', '2026-06-02 09:30+00'),
    (v_machine_b, 1, 4.00, 'cash', '2026-06-02 09:00+00');

  -- ─── Bank deposit (payout) @ T2 — must NOT anchor machines in per-machine mode ─
  INSERT INTO public.cash_book_entries
    (created_at, cash_book_id, company_id, type, amount, created_by)
    VALUES ('2026-06-02 12:00+00', v_book, v_company, 'payout', -2.00, v_user);

  -- ─── Authenticate as the company member ──────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  -- ═══ Test 1: track_per_machine = TRUE (the fix) ══════════════════════════
  r := public.get_theoretical_cash(v_book, v_company);
  RAISE NOTICE 'per-machine ON: %', r;
  SELECT (e->>'cash_sales')::float8 INTO a FROM jsonb_array_elements(r->'machines') e WHERE (e->>'machine_id')::uuid = v_machine_a;
  SELECT (e->>'cash_sales')::float8 INTO b FROM jsonb_array_elements(r->'machines') e WHERE (e->>'machine_id')::uuid = v_machine_b;

  ASSERT a = 0.50, format('A expected 0.50 (cash since ITS OWN withdrawal), got %s', a);
  ASSERT b = 8.00, format('B expected 8.00 (cash since initial — A''s withdrawal must NOT anchor B), got %s', b);
  ASSERT (r->>'cash_sales_since')::float8 = 8.50, format('cash_sales_since expected 8.50, got %s', r->>'cash_sales_since');
  ASSERT (r->>'theoretical_balance')::float8 = 10.00, format('theoretical_balance expected 10.00, got %s', r->>'theoretical_balance');
  ASSERT (r->>'last_entry_balance')::float8 = 1.50, format('last_entry_balance expected 1.50, got %s', r->>'last_entry_balance');
  ASSERT (r->>'entry_count')::int = 3, format('entry_count expected 3, got %s', r->>'entry_count');
  RAISE NOTICE 'Test 1 passed: per-machine anchoring scopes each machine to its own collection';

  -- ═══ Test 2: track_per_machine = FALSE (pre-fix whole-Barkasse behaviour) ═
  UPDATE public.cash_books SET track_per_machine = false WHERE id = v_book;
  r := public.get_theoretical_cash(v_book, v_company);
  RAISE NOTICE 'per-machine OFF: %', r;
  SELECT (e->>'cash_sales')::float8 INTO a FROM jsonb_array_elements(r->'machines') e WHERE (e->>'machine_id')::uuid = v_machine_a;
  SELECT (e->>'cash_sales')::float8 INTO b FROM jsonb_array_elements(r->'machines') e WHERE (e->>'machine_id')::uuid = v_machine_b;
  ASSERT a = 0.00, format('OFF: A expected 0.00 (since last entry = payout), got %s', a);
  ASSERT b = 0.00, format('OFF: B expected 0.00 (since last entry = payout), got %s', b);
  ASSERT (r->>'cash_sales_since')::float8 = 0.00, format('OFF: cash_sales_since expected 0.00, got %s', r->>'cash_sales_since');
  RAISE NOTICE 'Test 2 passed: track_per_machine=false reproduces unchanged behaviour';

  -- ═══ Test 3: non-member is rejected (NULL) ═══════════════════════════════
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_stranger::text, 'role', 'authenticated')::text, true);
  r := public.get_theoretical_cash(v_book, v_company);
  ASSERT r IS NULL, format('non-member must get NULL, got %s', r);
  RAISE NOTICE 'Test 3 passed: cross-company call rejected';

END $$;

ROLLBACK;

-- Seed (or re-seed) the App Store review demo organisation.
--
-- Idempotent: re-running wipes the previous demo company via the same
-- delete_company_and_data() the app uses, then rebuilds it with a FIXED id, so
-- it is safe to run before every submission (the reviewer deletes the account
-- per Guideline 5.1.1(v)).
--
-- Scope guard: every write is confined to the fixed demo company id below. It
-- never touches another tenant's rows.
--
-- Parameters (psql -v):
--   admin_email         demo login account (must already exist in auth.users)
--   second_admin_email  optional; '' = sole admin. If set, the org has two
--                       admins so deleting the demo account takes the ordinary
--                       one-tap path and the org survives (no company-name
--                       confirmation). Recommended for a smooth review.
--
-- Timestamps are relative to now() so KPIs are always populated.

\set ON_ERROR_STOP on

BEGIN;

-- psql interpolates :'var' only in normal lexer state, NOT inside a $$…$$ body.
-- Stash the parameters in transaction-local GUCs here (interpolation works), then
-- read them back with current_setting() inside the DO block.
SELECT set_config('demo.admin_email',        :'admin_email',        true),
       set_config('demo.second_admin_email', :'second_admin_email', true);

DO $$
DECLARE
  c_id      uuid := '00000000-de00-4000-a000-000000000001';  -- fixed demo company (valid v4-shaped uuid)
  v_admin   uuid;
  v_admin2  uuid := NULL;
  v_email   text := current_setting('demo.admin_email');
  v_email2  text := NULLIF(current_setting('demo.second_admin_email'), '');
  wh_id     uuid;
  dev1      uuid := gen_random_uuid();
  dev2      uuid := gen_random_uuid();
  dev3      uuid := gen_random_uuid();
  m1        uuid; m2 uuid; m3 uuid;
  p_cola    uuid := gen_random_uuid();
  p_water   uuid := gen_random_uuid();
  p_snick   uuid := gen_random_uuid();
  p_chips   uuid := gen_random_uuid();
  p_haribo  uuid := gen_random_uuid();
  d         int;
BEGIN
  -- Resolve the demo login account.
  SELECT id INTO v_admin FROM auth.users WHERE email = v_email;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'No auth user with email %. Create the demo login account first (register it in the app or Supabase Studio), then re-run.', v_email;
  END IF;

  -- Safety: never hijack a real operator. If this account already belongs to a
  -- company other than the demo one, refuse — use a dedicated throwaway login.
  IF EXISTS (SELECT 1 FROM public.organization_members
             WHERE user_id = v_admin AND company_id <> c_id) THEN
    RAISE EXCEPTION 'Account % already belongs to another company — use a dedicated demo login, not a real operator account.', v_email;
  END IF;

  IF v_email2 IS NOT NULL THEN
    SELECT id INTO v_admin2 FROM auth.users WHERE email = v_email2;
    IF v_admin2 IS NULL THEN
      RAISE EXCEPTION 'second_admin_email % has no auth user. Create it or pass '''' for a sole-admin demo.', v_email2;
    END IF;
  END IF;

  -- Idempotent reset: wipe any prior demo company with the app's own eraser.
  IF EXISTS (SELECT 1 FROM public.companies WHERE id = c_id) THEN
    PERFORM public.delete_company_and_data(c_id);
  END IF;

  -- Company + memberships
  INSERT INTO public.companies (id, name) VALUES (c_id, 'VMflow Demo GmbH');
  -- public.users profile rows must exist (created at signup); ensure company link
  UPDATE public.users SET company = c_id WHERE id = v_admin;
  INSERT INTO public.organization_members (company_id, user_id, role)
    VALUES (c_id, v_admin, 'admin')
    ON CONFLICT (company_id, user_id) DO UPDATE SET role = 'admin';
  IF v_admin2 IS NOT NULL THEN
    UPDATE public.users SET company = c_id WHERE id = v_admin2;
    INSERT INTO public.organization_members (company_id, user_id, role)
      VALUES (c_id, v_admin2, 'admin')
      ON CONFLICT (company_id, user_id) DO UPDATE SET role = 'admin';
  END IF;

  -- Products (image_path left NULL — renders a placeholder; point at real
  -- product-images bucket paths here if you want photos in the demo).
  INSERT INTO public.products (id, company, name, sellprice) VALUES
    (p_cola,   c_id, 'Cola Zero 0,5 l', 2.50),
    (p_water,  c_id, 'Wasser still 0,5 l', 1.50),
    (p_snick,  c_id, 'Snickers', 1.80),
    (p_chips,  c_id, 'Chips Paprika', 2.20),
    (p_haribo, c_id, 'Haribo Goldbären', 1.60);

  -- Devices (one offline) + machines
  INSERT INTO public.embeddeds (id, company, status, status_at) VALUES
    (dev1, c_id, 'online',  now()),
    (dev2, c_id, 'online',  now()),
    (dev3, c_id, 'offline', now() - interval '3 hours');
  INSERT INTO public."vendingMachine" (name, company, embedded) VALUES ('Snackomat West', c_id, dev1) RETURNING id INTO m1;
  INSERT INTO public."vendingMachine" (name, company, embedded) VALUES ('Automat Hauptbahnhof', c_id, dev2) RETURNING id INTO m2;
  INSERT INTO public."vendingMachine" (name, company, embedded) VALUES ('Foyer Süd', c_id, dev3) RETURNING id INTO m3;

  -- Trays: a spread of stock levels incl. some low, to make the dashboard alive.
  INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below) VALUES
    (m1, 11, p_cola,   10, 8, 3, 5),
    (m1, 12, p_water,  10, 2, 3, 5),
    (m1, 13, p_snick,  10, 6, 3, 5),
    (m1, 14, p_chips,  10, 0, 3, 5),
    (m2, 11, p_cola,   10, 9, 3, 5),
    (m2, 12, p_haribo, 10, 1, 3, 5),
    (m2, 13, p_snick,  10, 7, 3, 5),
    (m3, 11, p_water,  10, 5, 3, 5),
    (m3, 12, p_chips,  10, 4, 3, 5);

  -- Warehouse + FIFO batches
  INSERT INTO public.warehouses (company_id, name) VALUES (c_id, 'Zentrallager') RETURNING id INTO wh_id;
  INSERT INTO public.warehouse_stock_batches (warehouse_id, product_id, company_id, quantity, batch_number) VALUES
    (wh_id, p_cola,   c_id, 48, 'B-2026-07'),
    (wh_id, p_water,  c_id, 60, 'B-2026-07'),
    (wh_id, p_snick,  c_id, 36, 'B-2026-06'),
    (wh_id, p_chips,  c_id, 24, 'B-2026-07'),
    (wh_id, p_haribo, c_id, 40, 'B-2026-06');

  -- Sales over the last 30 days (triggers stamp machine_id/product_id and
  -- decrement stock, exactly like real sales). 3 today, then 1/day back.
  INSERT INTO public.sales (embedded_id, item_number, item_price, channel, created_at) VALUES
    (dev1, 11, 2.50, 'mdb', now() - interval '1 hour'),
    (dev1, 13, 1.80, 'mdb', now() - interval '2 hours'),
    (dev2, 11, 2.50, 'mdb', now() - interval '4 hours');
  FOR d IN 1..27 LOOP
    INSERT INTO public.sales (embedded_id, item_number, item_price, channel, created_at)
      VALUES ((ARRAY[dev1,dev2])[1 + (d % 2)], 11 + (d % 3), 1.50 + (d % 3), 'mdb',
              now() - make_interval(days => d, hours => (d % 6)));
  END LOOP;

  RAISE NOTICE 'Demo org seeded: company=% admin=% second_admin=% machines=3 products=5 sales≈30',
    c_id, v_email, coalesce(v_email2, '(none)');
END $$;

COMMIT;

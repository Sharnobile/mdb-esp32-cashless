-- =========================================================
-- Seed data — realistic production-like test environment
-- Runs after all migrations during `supabase db reset`
--
-- Scenario: "SnackFlow GmbH" operates 3 vending machines
-- across 2 locations with ~20 products, warehouse stock,
-- tax configuration, and 30 days of sales history.
-- =========================================================

-- Fixed UUIDs for referential integrity
-- User:       7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6  (test@test.com / password123)
-- Company:    be324c63-5b64-4d83-90e0-ae9f16703a69  (SnackFlow GmbH)
-- Embedded 1: e8f2e46c-4a97-4fc6-a01d-593e45c97276  (ESP32 #1)
-- Embedded 2: a1b2c3d4-1111-2222-3333-444455556666  (ESP32 #2)
-- Embedded 3: b2c3d4e5-2222-3333-4444-555566667777  (ESP32 #3)
-- Machine 1:  2a44d02e-49cd-4b43-b191-739c0d223278  (Büro Erdgeschoss)
-- Machine 2:  3b55e13f-5ace-5c54-c2a2-84ad61334389  (Büro 2. OG)
-- Machine 3:  4c66f240-6bdf-6d65-d3b3-95be72445490  (Fitnessstudio Lobby)
-- Warehouse:  d7e8f901-7777-8888-9999-aabbccddeeff  (Hauptlager)

-- ═══════════════════════════════════════════════════════════
-- 1. AUTH USER
-- ═══════════════════════════════════════════════════════════
INSERT INTO auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data,
  is_super_admin, is_sso_user, is_anonymous,
  confirmation_token, recovery_token, email_change_token_new,
  email_change_token_current, email_change, reauthentication_token,
  phone, phone_change, phone_change_token
) VALUES (
  '00000000-0000-0000-0000-000000000000',
  '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6',
  'authenticated', 'authenticated',
  'test@test.com',
  crypt('password123', gen_salt('bf')),
  now(), now() - interval '90 days', now(),
  '{"provider": "email", "providers": ["email"]}',
  '{"sub": "7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6", "email": "test@test.com", "email_verified": true, "phone_verified": false}',
  false, false, false,
  '', '', '', '', '', '', '', '', ''
);

INSERT INTO auth.identities (
  id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
) VALUES (
  '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6',
  '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6',
  '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6',
  jsonb_build_object('sub', '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6', 'email', 'test@test.com', 'email_verified', true),
  'email', now(), now() - interval '90 days', now()
);


-- ═══════════════════════════════════════════════════════════
-- 2. COMPANY
-- ═══════════════════════════════════════════════════════════
INSERT INTO public.companies (id, name, country_code, velocity_days)
VALUES ('be324c63-5b64-4d83-90e0-ae9f16703a69', 'SnackFlow GmbH', 'DE', 30);


-- ═══════════════════════════════════════════════════════════
-- 3. LINK USER → COMPANY
-- ═══════════════════════════════════════════════════════════
UPDATE public.users
SET company = 'be324c63-5b64-4d83-90e0-ae9f16703a69',
    first_name = 'Lucien',
    last_name = 'Kerl',
    email = 'test@test.com'
WHERE id = '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6';

INSERT INTO public.organization_members (company_id, user_id, role)
VALUES (
  'be324c63-5b64-4d83-90e0-ae9f16703a69',
  '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6',
  'admin'
);


-- ═══════════════════════════════════════════════════════════
-- 4. TAX CLASSES + RATES (DE)
-- ═══════════════════════════════════════════════════════════
INSERT INTO public.tax_classes (id, company_id, name, description, sort_order) VALUES
  ('a0a0a0a0-0000-4000-8000-000000000001', 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'standard',  'Regelsteuersatz 19%',    0),
  ('a0a0a0a0-0000-4000-8000-000000000002', 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'reduced',   'Ermäßigter Satz 7%',     1);

INSERT INTO public.tax_rates (company_id, tax_class_id, country_code, rate, name, valid_from) VALUES
  ('be324c63-5b64-4d83-90e0-ae9f16703a69', 'a0a0a0a0-0000-4000-8000-000000000001', 'DE', 0.1900, 'MwSt. 19%', '2007-01-01'),
  ('be324c63-5b64-4d83-90e0-ae9f16703a69', 'a0a0a0a0-0000-4000-8000-000000000002', 'DE', 0.0700, 'MwSt. 7%',  '2007-01-01');


-- ═══════════════════════════════════════════════════════════
-- 5. EMBEDDED DEVICES (3 ESP32s)
-- ═══════════════════════════════════════════════════════════
INSERT INTO public.embeddeds (id, owner_id, mac_address, status, status_at, passkey, company, firmware_version, firmware_build_date, online_since) VALUES
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6', '30:30:f9:16:86:fc', 'online',  now() - interval '2 hours', 'q7iGs8f>Pn9sxppb0(', 'be324c63-5b64-4d83-90e0-ae9f16703a69', '2.1.0', '2026-03-15T10:00:00+01:00', now() - interval '2 hours'),
  ('a1b2c3d4-1111-2222-3333-444455556666', '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6', 'A4:CF:12:8B:3E:01', 'online',  now() - interval '5 hours', 'xK9mN2pL7qRs4tUv8Y', 'be324c63-5b64-4d83-90e0-ae9f16703a69', '2.1.0', '2026-03-15T10:00:00+01:00', now() - interval '5 hours'),
  ('b2c3d4e5-2222-3333-4444-555566667777', '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6', 'B8:D6:1A:4C:72:FF', 'offline', now() - interval '1 day',   'jW3nP6kM8qTs2vXy5Z', 'be324c63-5b64-4d83-90e0-ae9f16703a69', '2.0.3', '2026-02-20T14:00:00+01:00', NULL);


-- ═══════════════════════════════════════════════════════════
-- 6. VENDING MACHINES (3)
-- ═══════════════════════════════════════════════════════════
INSERT INTO public."vendingMachine" (id, name, company, embedded, location_lat, location_lon) VALUES
  ('2a44d02e-49cd-4b43-b191-739c0d223278', 'Büro Erdgeschoss',    'be324c63-5b64-4d83-90e0-ae9f16703a69', 'e8f2e46c-4a97-4fc6-a01d-593e45c97276', 49.4875, 8.4660),
  ('3b55e13f-5ace-5c54-c2a2-84ad61334389', 'Büro 2. OG',          'be324c63-5b64-4d83-90e0-ae9f16703a69', 'a1b2c3d4-1111-2222-3333-444455556666', 49.4875, 8.4660),
  ('4c66f240-6bdf-6d65-d3b3-95be72445490', 'Fitnessstudio Lobby', 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b2c3d4e5-2222-3333-4444-555566667777', 49.4921, 8.4731);


-- ═══════════════════════════════════════════════════════════
-- 7. PRODUCT CATEGORIES (with tax classes)
-- ═══════════════════════════════════════════════════════════
INSERT INTO public.product_category (id, name, company, tax_class_id) VALUES
  ('b0b0b0b0-0000-4000-8000-000000000001', 'Snacks',          'be324c63-5b64-4d83-90e0-ae9f16703a69', 'a0a0a0a0-0000-4000-8000-000000000002'),
  ('b0b0b0b0-0000-4000-8000-000000000002', 'Kaltgetränke',    'be324c63-5b64-4d83-90e0-ae9f16703a69', 'a0a0a0a0-0000-4000-8000-000000000001'),
  ('b0b0b0b0-0000-4000-8000-000000000003', 'Heißgetränke',    'be324c63-5b64-4d83-90e0-ae9f16703a69', 'a0a0a0a0-0000-4000-8000-000000000001'),
  ('b0b0b0b0-0000-4000-8000-000000000004', 'Fitness & Riegel','be324c63-5b64-4d83-90e0-ae9f16703a69', 'a0a0a0a0-0000-4000-8000-000000000002');


-- ═══════════════════════════════════════════════════════════
-- 8. PRODUCTS (~20)
-- ═══════════════════════════════════════════════════════════
INSERT INTO public.products (id, name, sellprice, company, category, description) VALUES
  -- Snacks (7% MwSt.)
  ('c0c0c0c0-0000-4000-8000-000000000001', 'Haribo Goldbären',         1.20, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000001', '200g Beutel'),
  ('c0c0c0c0-0000-4000-8000-000000000002', 'Snickers',                 1.50, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000001', NULL),
  ('c0c0c0c0-0000-4000-8000-000000000003', 'Mars',                     1.50, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000001', NULL),
  ('c0c0c0c0-0000-4000-8000-000000000004', 'Twix',                     1.50, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000001', NULL),
  ('c0c0c0c0-0000-4000-8000-000000000005', 'Pringles Original',        2.50, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000001', '40g Dose'),
  ('c0c0c0c0-0000-4000-8000-000000000006', 'TUC Cracker',              1.30, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000001', NULL),
  -- Kaltgetränke (19% MwSt.)
  ('c0c0c0c0-0000-4000-8000-000000000007', 'Coca-Cola 0,33l',          2.00, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000002', 'Dose'),
  ('c0c0c0c0-0000-4000-8000-000000000008', 'Coca-Cola Zero 0,33l',     2.00, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000002', 'Dose'),
  ('c0c0c0c0-0000-4000-8000-000000000009', 'Fanta Orange 0,33l',       2.00, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000002', 'Dose'),
  ('c0c0c0c0-0000-4000-8000-00000000000a', 'Red Bull 0,25l',           2.80, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000002', 'Dose'),
  ('c0c0c0c0-0000-4000-8000-00000000000b', 'Red Bull Sugarfree 0,25l', 2.80, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000002', 'Dose'),
  ('c0c0c0c0-0000-4000-8000-00000000000c', 'Vio Wasser still 0,5l',    1.80, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000002', 'PET'),
  ('c0c0c0c0-0000-4000-8000-00000000000d', 'Vio Wasser medium 0,5l',   1.80, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000002', 'PET'),
  ('c0c0c0c0-0000-4000-8000-00000000000e', 'Eistee Pfirsich 0,33l',    2.00, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000002', 'Dose'),
  -- Heißgetränke (19% MwSt.)
  ('c0c0c0c0-0000-4000-8000-00000000000f', 'Kaffee schwarz',           1.00, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000003', 'Becher'),
  ('c0c0c0c0-0000-4000-8000-000000000010', 'Cappuccino',               1.50, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000003', 'Becher'),
  ('c0c0c0c0-0000-4000-8000-000000000011', 'Kakao',                    1.50, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000003', 'Becher'),
  -- Fitness & Riegel (7% MwSt.)
  ('c0c0c0c0-0000-4000-8000-000000000012', 'Cliff Bar Chocolate',      2.50, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000004', '68g'),
  ('c0c0c0c0-0000-4000-8000-000000000013', 'Powerbar Protein Plus',    3.00, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000004', '55g'),
  ('c0c0c0c0-0000-4000-8000-000000000014', 'Corny Nussvoll',           1.20, 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'b0b0b0b0-0000-4000-8000-000000000004', NULL);


-- ═══════════════════════════════════════════════════════════
-- 9. MACHINE TRAYS — Büro Erdgeschoss (10 Slots, Snacks + Drinks)
-- ═══════════════════════════════════════════════════════════
INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below) VALUES
  ('2a44d02e-49cd-4b43-b191-739c0d223278',  1, 'c0c0c0c0-0000-4000-8000-000000000007', 10,  8, 2, 5),  -- Cola
  ('2a44d02e-49cd-4b43-b191-739c0d223278',  2, 'c0c0c0c0-0000-4000-8000-000000000008', 10,  6, 2, 5),  -- Cola Zero
  ('2a44d02e-49cd-4b43-b191-739c0d223278',  3, 'c0c0c0c0-0000-4000-8000-000000000009', 10,  9, 2, 5),  -- Fanta
  ('2a44d02e-49cd-4b43-b191-739c0d223278',  4, 'c0c0c0c0-0000-4000-8000-00000000000a', 10,  3, 2, 5),  -- Red Bull
  ('2a44d02e-49cd-4b43-b191-739c0d223278',  5, 'c0c0c0c0-0000-4000-8000-00000000000c',  8,  5, 1, 4),  -- Vio still
  ('2a44d02e-49cd-4b43-b191-739c0d223278',  6, 'c0c0c0c0-0000-4000-8000-000000000001', 12, 10, 2, 6),  -- Haribo
  ('2a44d02e-49cd-4b43-b191-739c0d223278',  7, 'c0c0c0c0-0000-4000-8000-000000000002', 12,  4, 2, 6),  -- Snickers
  ('2a44d02e-49cd-4b43-b191-739c0d223278',  8, 'c0c0c0c0-0000-4000-8000-000000000003', 12,  7, 2, 6),  -- Mars
  ('2a44d02e-49cd-4b43-b191-739c0d223278',  9, 'c0c0c0c0-0000-4000-8000-000000000004', 12, 11, 2, 6),  -- Twix
  ('2a44d02e-49cd-4b43-b191-739c0d223278', 10, 'c0c0c0c0-0000-4000-8000-000000000005',  8,  2, 1, 4);  -- Pringles


-- ═══════════════════════════════════════════════════════════
-- 10. MACHINE TRAYS — Büro 2. OG (8 Slots, Drinks + Coffee)
-- ═══════════════════════════════════════════════════════════
INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below) VALUES
  ('3b55e13f-5ace-5c54-c2a2-84ad61334389',  1, 'c0c0c0c0-0000-4000-8000-000000000007', 10,  7, 2, 5),  -- Cola
  ('3b55e13f-5ace-5c54-c2a2-84ad61334389',  2, 'c0c0c0c0-0000-4000-8000-00000000000a', 10,  1, 2, 5),  -- Red Bull (low!)
  ('3b55e13f-5ace-5c54-c2a2-84ad61334389',  3, 'c0c0c0c0-0000-4000-8000-00000000000b', 10,  5, 2, 5),  -- Red Bull SF
  ('3b55e13f-5ace-5c54-c2a2-84ad61334389',  4, 'c0c0c0c0-0000-4000-8000-00000000000d',  8,  0, 1, 4),  -- Vio medium (empty!)
  ('3b55e13f-5ace-5c54-c2a2-84ad61334389',  5, 'c0c0c0c0-0000-4000-8000-00000000000f', 50, 32, 5, 20), -- Kaffee schwarz
  ('3b55e13f-5ace-5c54-c2a2-84ad61334389',  6, 'c0c0c0c0-0000-4000-8000-000000000010', 50, 18, 5, 20), -- Cappuccino
  ('3b55e13f-5ace-5c54-c2a2-84ad61334389',  7, 'c0c0c0c0-0000-4000-8000-000000000011', 50, 41, 5, 20), -- Kakao
  ('3b55e13f-5ace-5c54-c2a2-84ad61334389',  8, 'c0c0c0c0-0000-4000-8000-00000000000e', 10,  6, 2, 5);  -- Eistee


-- ═══════════════════════════════════════════════════════════
-- 11. MACHINE TRAYS — Fitnessstudio Lobby (8 Slots, Health + Drinks)
-- ═══════════════════════════════════════════════════════════
INSERT INTO public.machine_trays (machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below) VALUES
  ('4c66f240-6bdf-6d65-d3b3-95be72445490',  1, 'c0c0c0c0-0000-4000-8000-00000000000c', 10,  4, 2, 5),  -- Vio still
  ('4c66f240-6bdf-6d65-d3b3-95be72445490',  2, 'c0c0c0c0-0000-4000-8000-00000000000d', 10,  6, 2, 5),  -- Vio medium
  ('4c66f240-6bdf-6d65-d3b3-95be72445490',  3, 'c0c0c0c0-0000-4000-8000-00000000000a', 10,  0, 2, 5),  -- Red Bull (empty!)
  ('4c66f240-6bdf-6d65-d3b3-95be72445490',  4, 'c0c0c0c0-0000-4000-8000-00000000000b', 10,  3, 2, 5),  -- Red Bull SF
  ('4c66f240-6bdf-6d65-d3b3-95be72445490',  5, 'c0c0c0c0-0000-4000-8000-000000000012', 15, 12, 3, 8),  -- Cliff Bar
  ('4c66f240-6bdf-6d65-d3b3-95be72445490',  6, 'c0c0c0c0-0000-4000-8000-000000000013', 15,  7, 3, 8),  -- Powerbar
  ('4c66f240-6bdf-6d65-d3b3-95be72445490',  7, 'c0c0c0c0-0000-4000-8000-000000000014', 15, 14, 3, 8),  -- Corny
  ('4c66f240-6bdf-6d65-d3b3-95be72445490',  8, 'c0c0c0c0-0000-4000-8000-000000000002', 12,  9, 2, 6);  -- Snickers


-- ═══════════════════════════════════════════════════════════
-- 12. WAREHOUSE + STOCK
-- ═══════════════════════════════════════════════════════════
INSERT INTO public.warehouses (id, company_id, name, address)
VALUES ('d7e8f901-7777-8888-9999-aabbccddeeff', 'be324c63-5b64-4d83-90e0-ae9f16703a69', 'Hauptlager', 'Industriestr. 12, 68169 Mannheim');

-- Stock batches (FIFO — oldest expiry first)
INSERT INTO public.warehouse_stock_batches (warehouse_id, product_id, batch_number, expiration_date, quantity, company_id) VALUES
  -- Snacks
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-000000000001', 'HAR-2026-03', '2026-12-31', 48, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-000000000002', 'SNI-2026-02', '2026-09-30', 36, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-000000000003', 'MAR-2026-02', '2026-10-31', 36, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-000000000004', 'TWI-2026-03', '2026-11-30', 24, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-000000000005', 'PRI-2026-01', '2027-03-31', 16, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-000000000006', 'TUC-2026-02', '2027-01-31', 20, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  -- Kaltgetränke
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-000000000007', 'COK-2026-03', '2027-06-30', 72, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-000000000008', 'COZ-2026-03', '2027-06-30', 48, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-000000000009', 'FAN-2026-03', '2027-06-30', 48, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-00000000000a', 'RBL-2026-04', '2027-04-30', 60, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-00000000000b', 'RBS-2026-04', '2027-04-30', 36, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-00000000000c', 'VIS-2026-03', '2027-12-31', 24, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-00000000000d', 'VIM-2026-03', '2027-12-31', 24, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-00000000000e', 'ETP-2026-02', '2027-03-31', 30, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  -- Fitness
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-000000000012', 'CLF-2026-03', '2026-11-30', 20, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-000000000013', 'PWB-2026-03', '2026-12-31', 15, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('d7e8f901-7777-8888-9999-aabbccddeeff', 'c0c0c0c0-0000-4000-8000-000000000014', 'CRN-2026-02', '2027-02-28', 30, 'be324c63-5b64-4d83-90e0-ae9f16703a69');

-- Min stock alerts
INSERT INTO public.product_min_stock (product_id, warehouse_id, min_quantity, company_id) VALUES
  ('c0c0c0c0-0000-4000-8000-000000000007', 'd7e8f901-7777-8888-9999-aabbccddeeff', 20, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('c0c0c0c0-0000-4000-8000-00000000000a', 'd7e8f901-7777-8888-9999-aabbccddeeff', 15, 'be324c63-5b64-4d83-90e0-ae9f16703a69'),
  ('c0c0c0c0-0000-4000-8000-000000000002', 'd7e8f901-7777-8888-9999-aabbccddeeff', 10, 'be324c63-5b64-4d83-90e0-ae9f16703a69');


-- ═══════════════════════════════════════════════════════════
-- 13. SALES — 30 days of realistic sales across all 3 machines
--     Trigger auto-stamps machine_id + tax data
-- ═══════════════════════════════════════════════════════════
-- Machine 1: Büro Erdgeschoss — busy office, ~8 sales/day
INSERT INTO public.sales (embedded_id, item_price, item_number, channel, created_at) VALUES
  -- Today
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.00,  1, 'cashless', now() - interval '1 hour'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.80,  4, 'cashless', now() - interval '2 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 1.50,  7, 'cashless', now() - interval '3 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.00,  2, 'cashless', now() - interval '4 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 1.50,  8, 'cash',     now() - interval '5 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.50, 10, 'cashless', now() - interval '6 hours'),
  -- Yesterday
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.00,  1, 'cashless', now() - interval '1 day' - interval '2 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.00,  2, 'cashless', now() - interval '1 day' - interval '3 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.80,  4, 'cashless', now() - interval '1 day' - interval '4 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 1.20,  6, 'cash',     now() - interval '1 day' - interval '5 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 1.50,  7, 'cashless', now() - interval '1 day' - interval '6 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 1.50,  9, 'cashless', now() - interval '1 day' - interval '7 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.00,  3, 'cashless', now() - interval '1 day' - interval '8 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 1.80,  5, 'cash',     now() - interval '1 day' - interval '9 hours'),
  -- 2 days ago
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.80,  4, 'cashless', now() - interval '2 days' - interval '2 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.00,  1, 'cashless', now() - interval '2 days' - interval '4 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 1.50,  7, 'cash',     now() - interval '2 days' - interval '5 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.00,  2, 'cashless', now() - interval '2 days' - interval '6 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 1.50,  8, 'cashless', now() - interval '2 days' - interval '7 hours'),
  -- 3-7 days ago (sparser)
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.00,  1, 'cashless', now() - interval '3 days' - interval '3 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.80,  4, 'cashless', now() - interval '3 days' - interval '6 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 1.20,  6, 'cash',     now() - interval '4 days' - interval '2 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.00,  2, 'cashless', now() - interval '4 days' - interval '5 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 1.50,  7, 'cashless', now() - interval '5 days' - interval '4 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.50, 10, 'cashless', now() - interval '5 days' - interval '7 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.00,  3, 'cashless', now() - interval '6 days' - interval '3 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 1.50,  9, 'cash',     now() - interval '7 days' - interval '5 hours'),
  -- Weeks 2-4 (a few per week)
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.00,  1, 'cashless', now() - interval '10 days' - interval '3 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.80,  4, 'cashless', now() - interval '12 days' - interval '5 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 1.50,  7, 'cash',     now() - interval '14 days' - interval '2 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.00,  2, 'cashless', now() - interval '18 days' - interval '6 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 1.50,  8, 'cashless', now() - interval '21 days' - interval '4 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 2.00,  1, 'cashless', now() - interval '25 days' - interval '3 hours'),
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 1.80,  5, 'cash',     now() - interval '28 days' - interval '7 hours');

-- Machine 2: Büro 2. OG — coffee-heavy, ~6 sales/day
INSERT INTO public.sales (embedded_id, item_price, item_number, channel, created_at) VALUES
  -- Today
  ('a1b2c3d4-1111-2222-3333-444455556666', 1.00,  5, 'cashless', now() - interval '1 hour'),
  ('a1b2c3d4-1111-2222-3333-444455556666', 1.50,  6, 'cashless', now() - interval '2 hours'),
  ('a1b2c3d4-1111-2222-3333-444455556666', 2.80,  2, 'cashless', now() - interval '3 hours'),
  ('a1b2c3d4-1111-2222-3333-444455556666', 1.00,  5, 'cash',     now() - interval '5 hours'),
  ('a1b2c3d4-1111-2222-3333-444455556666', 1.50,  6, 'cashless', now() - interval '6 hours'),
  -- Yesterday
  ('a1b2c3d4-1111-2222-3333-444455556666', 1.00,  5, 'cashless', now() - interval '1 day' - interval '2 hours'),
  ('a1b2c3d4-1111-2222-3333-444455556666', 1.50,  6, 'cashless', now() - interval '1 day' - interval '3 hours'),
  ('a1b2c3d4-1111-2222-3333-444455556666', 1.50,  7, 'cashless', now() - interval '1 day' - interval '4 hours'),
  ('a1b2c3d4-1111-2222-3333-444455556666', 2.00,  1, 'cashless', now() - interval '1 day' - interval '5 hours'),
  ('a1b2c3d4-1111-2222-3333-444455556666', 2.80,  2, 'cashless', now() - interval '1 day' - interval '7 hours'),
  ('a1b2c3d4-1111-2222-3333-444455556666', 2.00,  8, 'cash',     now() - interval '1 day' - interval '8 hours'),
  -- Older
  ('a1b2c3d4-1111-2222-3333-444455556666', 1.00,  5, 'cashless', now() - interval '3 days' - interval '3 hours'),
  ('a1b2c3d4-1111-2222-3333-444455556666', 1.50,  6, 'cashless', now() - interval '3 days' - interval '5 hours'),
  ('a1b2c3d4-1111-2222-3333-444455556666', 2.80,  3, 'cashless', now() - interval '5 days' - interval '2 hours'),
  ('a1b2c3d4-1111-2222-3333-444455556666', 1.00,  5, 'cash',     now() - interval '7 days' - interval '4 hours'),
  ('a1b2c3d4-1111-2222-3333-444455556666', 1.50,  6, 'cashless', now() - interval '10 days' - interval '3 hours'),
  ('a1b2c3d4-1111-2222-3333-444455556666', 2.00,  1, 'cashless', now() - interval '14 days' - interval '6 hours'),
  ('a1b2c3d4-1111-2222-3333-444455556666', 1.50,  7, 'cashless', now() - interval '20 days' - interval '2 hours');

-- Machine 3: Fitnessstudio — protein bars + water, ~4 sales/day
INSERT INTO public.sales (embedded_id, item_price, item_number, channel, created_at) VALUES
  -- Today
  ('b2c3d4e5-2222-3333-4444-555566667777', 1.80,  1, 'cashless', now() - interval '2 hours'),
  ('b2c3d4e5-2222-3333-4444-555566667777', 2.50,  5, 'cashless', now() - interval '4 hours'),
  ('b2c3d4e5-2222-3333-4444-555566667777', 2.80,  3, 'cash',     now() - interval '6 hours'),
  -- Yesterday
  ('b2c3d4e5-2222-3333-4444-555566667777', 1.80,  2, 'cashless', now() - interval '1 day' - interval '2 hours'),
  ('b2c3d4e5-2222-3333-4444-555566667777', 3.00,  6, 'cashless', now() - interval '1 day' - interval '4 hours'),
  ('b2c3d4e5-2222-3333-4444-555566667777', 2.50,  5, 'cashless', now() - interval '1 day' - interval '6 hours'),
  ('b2c3d4e5-2222-3333-4444-555566667777', 1.50,  8, 'cash',     now() - interval '1 day' - interval '8 hours'),
  -- Older
  ('b2c3d4e5-2222-3333-4444-555566667777', 1.80,  1, 'cashless', now() - interval '3 days' - interval '3 hours'),
  ('b2c3d4e5-2222-3333-4444-555566667777', 2.80,  4, 'cashless', now() - interval '3 days' - interval '5 hours'),
  ('b2c3d4e5-2222-3333-4444-555566667777', 1.20,  7, 'cash',     now() - interval '5 days' - interval '2 hours'),
  ('b2c3d4e5-2222-3333-4444-555566667777', 2.50,  5, 'cashless', now() - interval '7 days' - interval '4 hours'),
  ('b2c3d4e5-2222-3333-4444-555566667777', 3.00,  6, 'cashless', now() - interval '10 days' - interval '6 hours'),
  ('b2c3d4e5-2222-3333-4444-555566667777', 1.80,  1, 'cashless', now() - interval '15 days' - interval '3 hours'),
  ('b2c3d4e5-2222-3333-4444-555566667777', 2.80,  3, 'cashless', now() - interval '22 days' - interval '5 hours');


-- ═══════════════════════════════════════════════════════════
-- 14. PAXCOUNTER (foot traffic)
-- ═══════════════════════════════════════════════════════════
INSERT INTO public.paxcounter (embedded_id, count) VALUES
  ('e8f2e46c-4a97-4fc6-a01d-593e45c97276', 142),
  ('a1b2c3d4-1111-2222-3333-444455556666', 87),
  ('b2c3d4e5-2222-3333-4444-555566667777', 53);


-- ═══════════════════════════════════════════════════════════
-- 15. DEVICE PROVISIONING (used tokens)
-- ═══════════════════════════════════════════════════════════
INSERT INTO public.device_provisioning (company_id, short_code, expires_at, created_by, used_at, embedded_id, name, device_only) VALUES
  ('be324c63-5b64-4d83-90e0-ae9f16703a69', 'B5M7EE2W', now() + interval '1 hour', '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6', now() - interval '80 days', 'e8f2e46c-4a97-4fc6-a01d-593e45c97276', 'ESP32 Büro EG',    false),
  ('be324c63-5b64-4d83-90e0-ae9f16703a69', 'K3NP8RV4', now() + interval '1 hour', '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6', now() - interval '60 days', 'a1b2c3d4-1111-2222-3333-444455556666', 'ESP32 Büro 2OG',   false),
  ('be324c63-5b64-4d83-90e0-ae9f16703a69', 'W9XT2HJ6', now() + interval '1 hour', '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6', now() - interval '45 days', 'b2c3d4e5-2222-3333-4444-555566667777', 'ESP32 Fitness',    false);


-- ═══════════════════════════════════════════════════════════
-- 16. ACTIVITY LOG (recent entries)
-- ═══════════════════════════════════════════════════════════
INSERT INTO public.activity_log (company_id, user_id, entity_type, entity_id, action, metadata, created_at) VALUES
  ('be324c63-5b64-4d83-90e0-ae9f16703a69', '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6', 'machine',  '2a44d02e-49cd-4b43-b191-739c0d223278', 'machine_created',  '{"name": "Büro Erdgeschoss"}'::jsonb,    now() - interval '80 days'),
  ('be324c63-5b64-4d83-90e0-ae9f16703a69', '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6', 'machine',  '3b55e13f-5ace-5c54-c2a2-84ad61334389', 'machine_created',  '{"name": "Büro 2. OG"}'::jsonb,          now() - interval '60 days'),
  ('be324c63-5b64-4d83-90e0-ae9f16703a69', '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6', 'machine',  '4c66f240-6bdf-6d65-d3b3-95be72445490', 'machine_created',  '{"name": "Fitnessstudio Lobby"}'::jsonb, now() - interval '45 days'),
  ('be324c63-5b64-4d83-90e0-ae9f16703a69', '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6', 'stock',    '2a44d02e-49cd-4b43-b191-739c0d223278', 'stock_refill_all', '{"machine_name": "Büro Erdgeschoss"}'::jsonb, now() - interval '3 days'),
  ('be324c63-5b64-4d83-90e0-ae9f16703a69', '7ee6e3e3-bfe1-412c-9c0e-b0d95bf98ac6', 'stock',    '3b55e13f-5ace-5c54-c2a2-84ad61334389', 'stock_refill_all', '{"machine_name": "Büro 2. OG"}'::jsonb,  now() - interval '3 days');


-- ═══════════════════════════════════════════════════════════
-- Done! Login with test@test.com / password123
-- ═══════════════════════════════════════════════════════════

# Einkaufspreise & Lieferanten — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let operators record per-product purchase prices (net+gross, multiple suppliers, history) and compare Marktguru deals against them, on both the PWA and the native iOS app.

**Architecture:** Two new company-scoped tables (`suppliers`, `product_purchase_prices`) + reusable SQL functions reused by both clients. A shared, pure comparison module is written once and ported 1:1 to TypeScript and Swift. A plausibility filter (deal gross > highest recorded EK gross → likely mismatch) is centralized in one SQL helper (`get_suppressed_offer_keys`) consumed by both the `get_new_deal_keys` RPC and the `deal-search` push path, so hidden offers never count or notify.

**Tech Stack:** PostgreSQL (Supabase migrations + plpgsql/sql functions, RLS via `my_company_id()`), Deno edge function (`deal-search`), Nuxt 4 PWA (TypeScript, Vitest), native iOS (SwiftUI, supabase-swift).

**Reference spec:** `docs/superpowers/specs/2026-06-14-einkaufspreise-lieferanten-design.md`

**Working branch:** work directly on `main` (this repo's convention; do NOT create a worktree). Commit per task; do not push unless asked.

**Critical project rules (read before starting):**
- **Migrations are immutable.** Only ever create NEW migration files. Changed functions use `CREATE OR REPLACE` in a new file. `.githooks/pre-commit` rejects edits to migrations already on `origin/main`.
- **Never run `supabase db reset`** — the local dev DB holds prod-synced data. Apply new migrations with `supabase migration up` (run from `Docker/supabase`).
- **Backward compatibility:** field-deployed firmware + older clients must keep working. All DB changes here are additive; the one replaced function (`get_new_deal_keys`) keeps its signature.
- **No generated DB types** in the PWA — cast Supabase results manually.
- `products.sellprice` / `sales.item_price` are EUR **floats** (`float8`), not cents — cast to `numeric` in money math.
- SECURITY DEFINER functions must set `search_path`; fully-qualify `public.*` table names.

---

## Chunk 1: Backend — tables, RLS, and purchase-price functions

Creates the data model and the CRUD/aggregation RPCs. All SQL is applied to the local dev DB with `supabase migration up` and tested with the `Docker/supabase/tests` ASSERT harness.

**Files:**
- Create: `Docker/supabase/migrations/20260614120000_suppliers_and_purchase_prices.sql`
- Create: `Docker/supabase/migrations/20260614120100_purchase_price_functions.sql`
- Create: `Docker/supabase/tests/purchase_prices.test.sql`

### Task 1.1: Create the tables + RLS migration

- [ ] **Step 1: Write the migration file**

Create `Docker/supabase/migrations/20260614120000_suppliers_and_purchase_prices.sql`:

```sql
-- Purchase prices & suppliers (Einkaufspreise / Lieferanten).
-- Two company-scoped tables, RLS modeled on tax_classes (20260406000000).
-- Additive only; safe on every existing install.

-- 1. suppliers ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.suppliers (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  name       text NOT NULL,
  CONSTRAINT suppliers_name_not_blank CHECK (length(btrim(name)) > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS suppliers_company_lower_name_uq
  ON public.suppliers (company_id, lower(btrim(name)));

ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "suppliers_select" ON public.suppliers;
CREATE POLICY "suppliers_select" ON public.suppliers
  FOR SELECT TO authenticated USING (company_id = public.my_company_id());
DROP POLICY IF EXISTS "suppliers_insert" ON public.suppliers;
CREATE POLICY "suppliers_insert" ON public.suppliers
  FOR INSERT TO authenticated WITH CHECK (company_id = public.my_company_id());
DROP POLICY IF EXISTS "suppliers_update" ON public.suppliers;
CREATE POLICY "suppliers_update" ON public.suppliers
  FOR UPDATE TO authenticated
  USING (company_id = public.my_company_id())
  WITH CHECK (company_id = public.my_company_id());
DROP POLICY IF EXISTS "suppliers_delete" ON public.suppliers;
CREATE POLICY "suppliers_delete" ON public.suppliers
  FOR DELETE TO authenticated USING (company_id = public.my_company_id());

-- 2. product_purchase_prices --------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_purchase_prices (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at  timestamptz NOT NULL DEFAULT now(),
  company_id  uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  product_id  uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  supplier_id uuid NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  price_net   numeric(10,4) NOT NULL,
  price_gross numeric(10,4) NOT NULL,
  price_basis text NOT NULL CHECK (price_basis IN ('net','gross')),
  tax_rate    numeric(6,4) NOT NULL,
  observed_on date NOT NULL DEFAULT CURRENT_DATE,
  note        text
);

CREATE INDEX IF NOT EXISTS product_purchase_prices_product_idx
  ON public.product_purchase_prices (product_id, observed_on DESC, created_at DESC);

ALTER TABLE public.product_purchase_prices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ppp_select" ON public.product_purchase_prices;
CREATE POLICY "ppp_select" ON public.product_purchase_prices
  FOR SELECT TO authenticated USING (company_id = public.my_company_id());
DROP POLICY IF EXISTS "ppp_insert" ON public.product_purchase_prices;
CREATE POLICY "ppp_insert" ON public.product_purchase_prices
  FOR INSERT TO authenticated WITH CHECK (company_id = public.my_company_id());
DROP POLICY IF EXISTS "ppp_update" ON public.product_purchase_prices;
CREATE POLICY "ppp_update" ON public.product_purchase_prices
  FOR UPDATE TO authenticated
  USING (company_id = public.my_company_id())
  WITH CHECK (company_id = public.my_company_id());
DROP POLICY IF EXISTS "ppp_delete" ON public.product_purchase_prices;
CREATE POLICY "ppp_delete" ON public.product_purchase_prices
  FOR DELETE TO authenticated USING (company_id = public.my_company_id());
```

- [ ] **Step 2: Apply the migration to the local dev DB**

Run (from repo root):
```bash
cd Docker/supabase && supabase migration up && cd ../..
```
Expected: applies `20260614120000_…` with no error. (Do NOT use `supabase db reset`.)

- [ ] **Step 3: Verify tables + RLS exist**

Run:
```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c "\d+ public.product_purchase_prices" -c "\dp public.suppliers"
```
Expected: both tables exist; `rowsecurity` on; 4 policies each.

- [ ] **Step 4: Commit**

```bash
git add Docker/supabase/migrations/20260614120000_suppliers_and_purchase_prices.sql
git commit -m "feat(db): add suppliers + product_purchase_prices tables with RLS"
```

### Task 1.2: Write the failing SQL test for the functions

This test is written BEFORE the functions exist, so it fails at first run. It uses the ASSERT-in-rolled-back-transaction harness (see `Docker/supabase/tests/get_product_detail_kpis.test.sql` for the exact pattern: fake JWT via `set_config('request.jwt.claims', …, true)`).

- [ ] **Step 1: Write the test file**

Create `Docker/supabase/tests/purchase_prices.test.sql`:

```sql
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
```

- [ ] **Step 2: Run the test, expect FAIL (functions missing)**

Run:
```bash
bash Docker/supabase/tests/run-sql-tests.sh
```
Expected: FAIL on `purchase_prices.test.sql` with an error like `function public.resolve_product_tax_rate(uuid) does not exist`.

### Task 1.3: Implement the functions migration

- [ ] **Step 1: Write the functions migration**

Create `Docker/supabase/migrations/20260614120100_purchase_price_functions.sql`:

```sql
-- Purchase-price functions. All SECURITY DEFINER, fully-qualified names,
-- search_path=public (none use pgcrypto). Reuse the sales-trigger tax logic,
-- adapted product-centrically (company/country from products.company +
-- companies.country_code, NOT vendingMachine).

-- resolve_product_tax_rate ----------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_product_tax_rate(
  p_product_id uuid, p_on date DEFAULT CURRENT_DATE
) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_company uuid; v_country char(2); v_class uuid; v_rate numeric(6,4);
BEGIN
  SELECT p.company, COALESCE(p.tax_class_id, pc.tax_class_id)
    INTO v_company, v_class
  FROM public.products p
  LEFT JOIN public.product_category pc ON pc.id = p.category
  WHERE p.id = p_product_id;

  IF v_company IS NULL OR v_class IS NULL THEN RETURN NULL; END IF;

  SELECT COALESCE(c.country_code, 'DE') INTO v_country
  FROM public.companies c WHERE c.id = v_company;

  SELECT tr.rate INTO v_rate
  FROM public.tax_rates tr
  WHERE tr.company_id = v_company AND tr.tax_class_id = v_class
    AND tr.country_code = v_country
    AND tr.valid_from <= p_on
    AND (tr.valid_to IS NULL OR tr.valid_to >= p_on)
  ORDER BY tr.valid_from DESC LIMIT 1;

  RETURN v_rate;
END $$;

-- add_purchase_price ----------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_purchase_price(
  p_product_id uuid, p_supplier_name text, p_price numeric, p_basis text,
  p_observed_on date DEFAULT CURRENT_DATE, p_note text DEFAULT NULL,
  p_tax_rate_override numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_company uuid := public.my_company_id();
  v_name text := btrim(coalesce(p_supplier_name, ''));
  v_supplier uuid; v_rate numeric(6,4); v_net numeric(10,4); v_gross numeric(10,4); v_id uuid;
BEGIN
  IF v_company IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_basis NOT IN ('net','gross') THEN RAISE EXCEPTION 'invalid basis: %', p_basis; END IF;
  IF v_name = '' THEN RAISE EXCEPTION 'supplier name required'; END IF;
  PERFORM 1 FROM public.products WHERE id = p_product_id AND company = v_company;
  IF NOT FOUND THEN RAISE EXCEPTION 'product not found or access denied'; END IF;

  SELECT id INTO v_supplier FROM public.suppliers
  WHERE company_id = v_company AND lower(btrim(name)) = lower(v_name);
  IF v_supplier IS NULL THEN
    INSERT INTO public.suppliers (company_id, name) VALUES (v_company, v_name)
    RETURNING id INTO v_supplier;
  END IF;

  v_rate := COALESCE(p_tax_rate_override, public.resolve_product_tax_rate(p_product_id, p_observed_on));
  IF v_rate IS NULL THEN RAISE EXCEPTION 'tax_rate_required'; END IF;

  IF p_basis = 'net' THEN
    v_net := round(p_price::numeric, 4);
    v_gross := round(p_price::numeric * (1 + v_rate), 4);
  ELSE
    v_gross := round(p_price::numeric, 4);
    v_net := round(p_price::numeric / (1 + v_rate), 4);
  END IF;

  INSERT INTO public.product_purchase_prices
    (company_id, product_id, supplier_id, price_net, price_gross, price_basis, tax_rate, observed_on, note)
  VALUES (v_company, p_product_id, v_supplier, v_net, v_gross, p_basis, v_rate, p_observed_on, p_note)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'id', v_id, 'product_id', p_product_id, 'supplier_id', v_supplier, 'supplier_name', v_name,
    'price_net', v_net, 'price_gross', v_gross, 'price_basis', p_basis, 'tax_rate', v_rate,
    'observed_on', p_observed_on, 'note', p_note
  );
END $$;

-- update_purchase_price -------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_purchase_price(
  p_id uuid, p_supplier_name text, p_price numeric, p_basis text,
  p_observed_on date, p_note text DEFAULT NULL, p_tax_rate_override numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_company uuid := public.my_company_id();
  v_name text := btrim(coalesce(p_supplier_name, ''));
  v_product uuid; v_supplier uuid; v_rate numeric(6,4); v_net numeric(10,4); v_gross numeric(10,4);
BEGIN
  IF v_company IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_basis NOT IN ('net','gross') THEN RAISE EXCEPTION 'invalid basis: %', p_basis; END IF;
  IF v_name = '' THEN RAISE EXCEPTION 'supplier name required'; END IF;

  SELECT product_id INTO v_product FROM public.product_purchase_prices
  WHERE id = p_id AND company_id = v_company;
  IF v_product IS NULL THEN RAISE EXCEPTION 'purchase price not found or access denied'; END IF;

  SELECT id INTO v_supplier FROM public.suppliers
  WHERE company_id = v_company AND lower(btrim(name)) = lower(v_name);
  IF v_supplier IS NULL THEN
    INSERT INTO public.suppliers (company_id, name) VALUES (v_company, v_name)
    RETURNING id INTO v_supplier;
  END IF;

  v_rate := COALESCE(p_tax_rate_override, public.resolve_product_tax_rate(v_product, p_observed_on));
  IF v_rate IS NULL THEN RAISE EXCEPTION 'tax_rate_required'; END IF;

  IF p_basis = 'net' THEN
    v_net := round(p_price::numeric, 4); v_gross := round(p_price::numeric * (1 + v_rate), 4);
  ELSE
    v_gross := round(p_price::numeric, 4); v_net := round(p_price::numeric / (1 + v_rate), 4);
  END IF;

  UPDATE public.product_purchase_prices
  SET supplier_id = v_supplier, price_net = v_net, price_gross = v_gross,
      price_basis = p_basis, tax_rate = v_rate, observed_on = p_observed_on, note = p_note
  WHERE id = p_id AND company_id = v_company;

  RETURN jsonb_build_object(
    'id', p_id, 'product_id', v_product, 'supplier_id', v_supplier, 'supplier_name', v_name,
    'price_net', v_net, 'price_gross', v_gross, 'price_basis', p_basis, 'tax_rate', v_rate,
    'observed_on', p_observed_on, 'note', p_note
  );
END $$;

-- get_product_purchase_summary ------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_product_purchase_summary(p_product_ids uuid[])
RETURNS TABLE (
  product_id uuid, ek_count int,
  newest_net numeric, newest_gross numeric, newest_supplier text, newest_on date,
  min_gross numeric, min_supplier text, min_on date,
  max_gross numeric, effective_tax_rate numeric
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH mine AS (
    SELECT p.id FROM public.products p
    WHERE p.id = ANY(p_product_ids) AND p.company = public.my_company_id()
  ),
  ranked AS (
    SELECT pp.product_id, pp.price_net, pp.price_gross, pp.observed_on, s.name AS supplier_name,
           row_number() OVER (PARTITION BY pp.product_id ORDER BY pp.observed_on DESC, pp.created_at DESC) AS rn_new,
           row_number() OVER (PARTITION BY pp.product_id ORDER BY pp.price_gross ASC, pp.observed_on DESC) AS rn_min
    FROM public.product_purchase_prices pp
    JOIN mine m ON m.id = pp.product_id
    JOIN public.suppliers s ON s.id = pp.supplier_id
  )
  SELECT
    m.id,
    (SELECT count(*) FROM ranked r WHERE r.product_id = m.id)::int,
    (SELECT r.price_net    FROM ranked r WHERE r.product_id = m.id AND r.rn_new = 1),
    (SELECT r.price_gross  FROM ranked r WHERE r.product_id = m.id AND r.rn_new = 1),
    (SELECT r.supplier_name FROM ranked r WHERE r.product_id = m.id AND r.rn_new = 1),
    (SELECT r.observed_on  FROM ranked r WHERE r.product_id = m.id AND r.rn_new = 1),
    (SELECT r.price_gross  FROM ranked r WHERE r.product_id = m.id AND r.rn_min = 1),
    (SELECT r.supplier_name FROM ranked r WHERE r.product_id = m.id AND r.rn_min = 1),
    (SELECT r.observed_on  FROM ranked r WHERE r.product_id = m.id AND r.rn_min = 1),
    (SELECT max(r.price_gross) FROM ranked r WHERE r.product_id = m.id),
    public.resolve_product_tax_rate(m.id)
  FROM mine m;
$$;

GRANT EXECUTE ON FUNCTION public.resolve_product_tax_rate(uuid, date)             TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_purchase_price(uuid, text, numeric, text, date, text, numeric)    TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_purchase_price(uuid, text, numeric, text, date, text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_product_purchase_summary(uuid[])             TO authenticated;
```

- [ ] **Step 2: Apply the migration**

Run:
```bash
cd Docker/supabase && supabase migration up && cd ../..
```
Expected: applies `20260614120100_…` with no error.

- [ ] **Step 3: Run the SQL test, expect PASS**

Run:
```bash
bash Docker/supabase/tests/run-sql-tests.sh
```
Expected: `purchase_prices.test.sql` → PASS (all 6 NOTICEs print).

- [ ] **Step 4: Commit**

```bash
git add Docker/supabase/migrations/20260614120100_purchase_price_functions.sql Docker/supabase/tests/purchase_prices.test.sql
git commit -m "feat(db): purchase-price functions (resolve rate, add/update, summary) + SQL test"
```

---

## Chunk 2: Backend — plausibility filter (suppression) + deal-search push

Centralizes the "deal gross > highest recorded EK gross → suppress" rule in one SQL helper and wires it into the new-deal RPC and the deal-search push so hidden offers never count or notify. **Backward-compatible:** with no EK rows the helper returns nothing and behavior is identical to today.

**Files:**
- Create: `Docker/supabase/migrations/20260614120200_deal_plausibility_filter.sql`
- Create: `Docker/supabase/tests/deal_plausibility.test.sql`
- Modify: `Docker/supabase/functions/deal-search/index.ts` (new-offer counting block, ~lines 754–792)

### Task 2.1: Write the failing SQL test for the suppression helper

- [ ] **Step 1: Write the test file**

Create `Docker/supabase/tests/deal_plausibility.test.sql`:

```sql
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
```

- [ ] **Step 2: Run, expect FAIL (helper missing)**

Run:
```bash
bash Docker/supabase/tests/run-sql-tests.sh
```
Expected: FAIL on `deal_plausibility.test.sql` with `function public.get_suppressed_offer_keys(uuid) does not exist`.

### Task 2.2: Implement the suppression migration

- [ ] **Step 1: Read the current `get_new_deal_keys` body**

Open `Docker/supabase/migrations/20260530120000_daily_deal_refresh.sql` lines 83–127. The `CREATE OR REPLACE` below MUST reproduce that body verbatim (baseline lazy-insert + read, the `deal_offer_first_seen` join, and the `NOT EXISTS … deal_user_state … (pinned_at OR archived_at)` clause) and only ADD the new suppression clause. Do not drop any existing logic.

- [ ] **Step 2: Write the migration**

Create `Docker/supabase/migrations/20260614120200_deal_plausibility_filter.sql`:

```sql
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
```

- [ ] **Step 3: Apply the migration**

Run:
```bash
cd Docker/supabase && supabase migration up && cd ../..
```
Expected: applies `20260614120200_…` cleanly.

- [ ] **Step 4: Run the SQL tests, expect PASS**

Run:
```bash
bash Docker/supabase/tests/run-sql-tests.sh
```
Expected: both `purchase_prices.test.sql` and `deal_plausibility.test.sql` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Docker/supabase/migrations/20260614120200_deal_plausibility_filter.sql Docker/supabase/tests/deal_plausibility.test.sql
git commit -m "feat(db): deal plausibility filter (get_suppressed_offer_keys) + exclude from get_new_deal_keys"
```

### Task 2.3: Exclude suppressed offers from the deal-search push count

The new-deals push is generated in `deal-search/index.ts`. After the newly-first-seen offers are computed (`inserted` → `newOfferCount`/`newRetailers`), filter out suppressed offers before the push fires.

- [ ] **Step 1: Locate the block**

Open `Docker/supabase/functions/deal-search/index.ts`. Find the block (≈ lines 759–771) that sets `newOfferCount` and `newRetailers` from the `inserted` rows of the `deal_offer_first_seen` upsert, immediately before the `if (isScheduled && newOfferCount > 0)` push block.

- [ ] **Step 2: Insert the suppression filter**

Immediately after the line `newRetailers = [...new Set((inserted ?? []).map((r: any) => r.retailer))]` (still inside the `else` branch where `inserted` is in scope), add:

```ts
        // Exclude implausible offers (deal price above the highest recorded EK
        // for ALL matched products) from the new-deal count + push, so junk/
        // mismatched matches never nudge users. No EK data → empty set → no-op.
        try {
          const { data: suppressed } = await adminClient
            .rpc('get_suppressed_offer_keys', { p_company_id: companyId })
          const suppressedSet = new Set(
            (suppressed ?? []).map((s: any) => `${s.retailer}::${s.offer_id}`),
          )
          if (suppressedSet.size > 0) {
            const survivors = (inserted ?? []).filter(
              (r: any) => !suppressedSet.has(`${r.retailer}::${r.offer_id}`),
            )
            newOfferCount = survivors.length
            newRetailers = [...new Set(survivors.map((r: any) => r.retailer))]
          }
        } catch (suppErr) {
          console.error('[deal-search] suppression filter failed (counting all):', suppErr)
        }
```

- [ ] **Step 3: Type-check the edge function**

Run:
```bash
cd Docker/supabase/functions && deno check deal-search/index.ts && cd ../../..
```
Expected: no type errors. (If `deno` is unavailable locally, note it and rely on the SQL test for the helper; the TS change is a small additive filter.)

- [ ] **Step 4: Manual verification note (no automated edge-fn test)**

The suppression *logic* is covered by `deal_plausibility.test.sql`. This step only re-counts using that logic. Document a manual check in the commit body: with a product whose recorded EK gross is below a freshly-inserted offer's `deal_price`, a scheduled `deal-search` run must not include that offer in the push count.

- [ ] **Step 5: Commit**

```bash
git add Docker/supabase/functions/deal-search/index.ts
git commit -m "feat(deal-search): exclude implausible (above-max-EK) offers from new-deal push count"
```

---

## Chunk 3: PWA — shared comparison module + purchase-price composable

The pure comparison logic (`purchaseComparison.ts`) is the single source of truth for verdicts/margins; it is unit-tested and later ported 1:1 to Swift (Chunk 6). The composable (`usePurchasePrices.ts`) wraps the RPCs from Chunk 1 and the suppliers/prices tables.

**Files:**
- Create: `management-frontend/app/lib/purchaseComparison.ts`
- Create: `management-frontend/app/lib/__tests__/purchaseComparison.test.ts`
- Create: `management-frontend/app/composables/usePurchasePrices.ts`

### Task 3.1: Write the failing test for the pure comparison module

- [ ] **Step 1: Write the test**

Create `management-frontend/app/lib/__tests__/purchaseComparison.test.ts`:

```ts
import { describe, it, expect } from 'vitest'
import {
  counterpart, marginNet, classifyDeal, marginDelta, isCardSuppressed,
  type PurchaseSummary,
} from '../purchaseComparison'

function summary(over: Partial<PurchaseSummary>): PurchaseSummary {
  return {
    product_id: 'p', ek_count: 1,
    newest_net: 0.50, newest_gross: 0.54, newest_supplier: 'Müller', newest_on: '2026-06-01',
    min_gross: 0.51, min_supplier: 'Metro', min_on: '2026-03-01',
    max_gross: 0.55, effective_tax_rate: 0.07, ...over,
  }
}

describe('counterpart', () => {
  it('net → gross at 7%', () => expect(counterpart(0.50, 'net', 0.07)).toBeCloseTo(0.535, 4))
  it('gross → net at 7%', () => expect(counterpart(0.535, 'gross', 0.07)).toBeCloseTo(0.50, 4))
})

describe('marginNet', () => {
  it('VK_net − EK_net on net basis', () => {
    const m = marginNet(1.20, 0.50, 0.07)!
    expect(m.rohertrag).toBeCloseTo(1.20 / 1.07 - 0.50, 4)
    expect(m.spannePct).toBeGreaterThan(40)
  })
  it('returns null when sellprice missing', () => expect(marginNet(null, 0.50, 0.07)).toBeNull())
})

describe('classifyDeal', () => {
  it('no_ek when summary empty', () =>
    expect(classifyDeal(0.45, summary({ ek_count: 0, max_gross: null, newest_gross: null })).verdict).toBe('no_ek'))
  it('implausible when above max', () =>
    expect(classifyDeal(2.99, summary({})).verdict).toBe('implausible'))
  it('good_best when at/below min', () =>
    expect(classifyDeal(0.45, summary({})).verdict).toBe('good_best'))
  it('good when below usual beyond tolerance', () =>
    expect(classifyDeal(0.52, summary({ min_gross: 0.40 })).verdict).toBe('good'))
  it('similar within ±3% of newest', () =>
    expect(classifyDeal(0.545, summary({ min_gross: 0.40 })).verdict).toBe('similar'))
  it('worse above usual but ≤ max', () =>
    expect(classifyDeal(0.549, summary({ min_gross: 0.40, newest_gross: 0.50, max_gross: 0.60 })).verdict).toBe('worse'))
  it('single-EK: equal value is good_best, just above is implausible', () => {
    const single = summary({ min_gross: 0.54, max_gross: 0.54, newest_gross: 0.54, ek_count: 1 })
    expect(classifyDeal(0.54, single).verdict).toBe('good_best')
    expect(classifyDeal(0.541, single).verdict).toBe('implausible')
  })
})

describe('isCardSuppressed', () => {
  it('all implausible → suppressed', () => expect(isCardSuppressed(['implausible', 'implausible'])).toBe(true))
  it('one no_ek keeps it visible', () => expect(isCardSuppressed(['implausible', 'no_ek'])).toBe(false))
  it('empty → not suppressed', () => expect(isCardSuppressed([])).toBe(false))
})

describe('marginDelta', () => {
  it('computes current vs deal margin on net basis', () => {
    const md = marginDelta(1.20, 0.45, summary({}))!
    // VK_net = 1.20/1.07 ≈ 1.1215; current = (1.1215-0.50)/1.1215; deal uses dealNet 0.45/1.07
    expect(md.dealPct).toBeGreaterThan(md.currentPct)
  })
  it('null when sellprice missing', () => expect(marginDelta(null, 0.45, summary({}))).toBeNull())
})
```

- [ ] **Step 2: Run it, expect FAIL (module missing)**

Run:
```bash
cd management-frontend && npx vitest run app/lib/__tests__/purchaseComparison.test.ts; cd ..
```
Expected: FAIL — cannot resolve `../purchaseComparison`.

### Task 3.2: Implement the pure comparison module

- [ ] **Step 1: Write the module**

Create `management-frontend/app/lib/purchaseComparison.ts`:

```ts
// Pure, framework-free purchase-price comparison logic.
// PORTED 1:1 to ios/VMflow/Utilities/PurchaseComparison.swift — keep in sync.

export type PriceBasis = 'net' | 'gross'

export interface PurchaseSummary {
  product_id: string
  ek_count: number
  newest_net: number | null
  newest_gross: number | null
  newest_supplier: string | null
  newest_on: string | null
  min_gross: number | null
  min_supplier: string | null
  min_on: string | null
  max_gross: number | null
  effective_tax_rate: number | null
}

export type DealVerdict = 'no_ek' | 'implausible' | 'good_best' | 'good' | 'similar' | 'worse'

export interface DealComparison {
  verdict: DealVerdict
  deltaPct: number | null // vs newest (üblicher) gross; negative = cheaper
}

const round4 = (n: number) => Math.round(n * 1e4) / 1e4

/** Counterpart price from one entered value + basis + tax rate. */
export function counterpart(value: number, basis: PriceBasis, rate: number): number {
  return basis === 'net' ? round4(value * (1 + rate)) : round4(value / (1 + rate))
}

/** Net-basis margin VK_net − EK_net. Null if inputs missing or VK_net ≤ 0. */
export function marginNet(
  sellpriceGross: number | null,
  ekNet: number | null,
  rate: number | null,
): { rohertrag: number; spannePct: number } | null {
  if (sellpriceGross == null || ekNet == null || rate == null) return null
  const vkNet = sellpriceGross / (1 + rate)
  if (vkNet <= 0) return null
  const rohertrag = vkNet - ekNet
  return { rohertrag, spannePct: (rohertrag / vkNet) * 100 }
}

/** Classify a deal's gross price against the product's EK summary. */
export function classifyDeal(
  dealGross: number | null,
  summary: PurchaseSummary | null | undefined,
  tolerancePct = 3,
): DealComparison {
  if (
    dealGross == null || !summary || summary.ek_count === 0 ||
    summary.max_gross == null || summary.newest_gross == null
  ) {
    return { verdict: 'no_ek', deltaPct: null }
  }
  const deltaPct = ((dealGross - summary.newest_gross) / summary.newest_gross) * 100
  if (dealGross > summary.max_gross) return { verdict: 'implausible', deltaPct }
  if (summary.min_gross != null && dealGross <= summary.min_gross) return { verdict: 'good_best', deltaPct }
  if (dealGross < summary.newest_gross && Math.abs(deltaPct) > tolerancePct) return { verdict: 'good', deltaPct }
  if (Math.abs(deltaPct) <= tolerancePct) return { verdict: 'similar', deltaPct }
  return { verdict: 'worse', deltaPct }
}

/** Margin if the deal replaced the usual EK (green-case display). Null if not computable. */
export function marginDelta(
  sellpriceGross: number | null,
  dealGross: number,
  summary: PurchaseSummary,
): { currentPct: number; dealPct: number } | null {
  const rate = summary.effective_tax_rate
  if (sellpriceGross == null || rate == null || summary.newest_net == null) return null
  const vkNet = sellpriceGross / (1 + rate)
  if (vkNet <= 0) return null
  const dealNet = dealGross / (1 + rate)
  return {
    currentPct: ((vkNet - summary.newest_net) / vkNet) * 100,
    dealPct: ((vkNet - dealNet) / vkNet) * 100,
  }
}

/** A deal card is suppressed iff it has matched products and ALL are implausible. */
export function isCardSuppressed(verdicts: DealVerdict[]): boolean {
  return verdicts.length > 0 && verdicts.every((v) => v === 'implausible')
}
```

- [ ] **Step 2: Run the test, expect PASS**

Run:
```bash
cd management-frontend && npx vitest run app/lib/__tests__/purchaseComparison.test.ts; cd ..
```
Expected: PASS (all cases green).

- [ ] **Step 3: Commit**

```bash
git add management-frontend/app/lib/purchaseComparison.ts management-frontend/app/lib/__tests__/purchaseComparison.test.ts
git commit -m "feat(pwa): pure purchase-price comparison module + tests"
```

### Task 3.3: Create the `usePurchasePrices` composable

Thin RPC/table wrappers, modeled on `useProducts.ts` (`useState`, `useSupabaseClient`, manual casts — no generated types).

- [ ] **Step 1: Write the composable**

Create `management-frontend/app/composables/usePurchasePrices.ts`:

```ts
import { useSupabaseClient } from '#imports'
import type { PurchaseSummary } from '~/lib/purchaseComparison'

export interface Supplier { id: string; name: string }

export interface PurchasePrice {
  id: string
  product_id: string
  supplier_id: string
  supplier_name: string
  price_net: number
  price_gross: number
  price_basis: 'net' | 'gross'
  tax_rate: number
  observed_on: string
  note: string | null
}

interface PriceInput {
  productId: string
  supplierName: string
  price: number
  basis: 'net' | 'gross'
  observedOn: string
  note?: string | null
  taxRateOverride?: number | null
}

export function usePurchasePrices() {
  const suppliers = useState<Supplier[]>('suppliers', () => [])

  async function fetchSuppliers() {
    const supabase = useSupabaseClient()
    const { data, error } = await supabase.from('suppliers').select('id, name').order('name')
    if (error) throw error
    suppliers.value = (data ?? []) as Supplier[]
  }

  async function fetchPurchasePrices(productId: string): Promise<PurchasePrice[]> {
    const supabase = useSupabaseClient()
    const { data, error } = await supabase
      .from('product_purchase_prices')
      .select('id, product_id, supplier_id, price_net, price_gross, price_basis, tax_rate, observed_on, note, suppliers(name)')
      .eq('product_id', productId)
      .order('observed_on', { ascending: false })
      .order('created_at', { ascending: false })
    if (error) throw error
    return ((data ?? []) as any[]).map((r) => ({
      id: r.id,
      product_id: r.product_id,
      supplier_id: r.supplier_id,
      supplier_name: r.suppliers?.name ?? '',
      price_net: Number(r.price_net),
      price_gross: Number(r.price_gross),
      price_basis: r.price_basis,
      tax_rate: Number(r.tax_rate),
      observed_on: r.observed_on,
      note: r.note,
    }))
  }

  async function resolveTaxRate(productId: string): Promise<number | null> {
    const supabase = useSupabaseClient()
    const { data, error } = await supabase.rpc('resolve_product_tax_rate', { p_product_id: productId })
    if (error) throw error
    return data == null ? null : Number(data)
  }

  async function addPurchasePrice(input: PriceInput): Promise<PurchasePrice> {
    const supabase = useSupabaseClient()
    const { data, error } = await supabase.rpc('add_purchase_price', {
      p_product_id: input.productId,
      p_supplier_name: input.supplierName,
      p_price: input.price,
      p_basis: input.basis,
      p_observed_on: input.observedOn,
      p_note: input.note ?? null,
      p_tax_rate_override: input.taxRateOverride ?? null,
    })
    if (error) throw error
    await fetchSuppliers()
    return data as PurchasePrice
  }

  async function updatePurchasePrice(id: string, input: PriceInput): Promise<PurchasePrice> {
    const supabase = useSupabaseClient()
    const { data, error } = await supabase.rpc('update_purchase_price', {
      p_id: id,
      p_supplier_name: input.supplierName,
      p_price: input.price,
      p_basis: input.basis,
      p_observed_on: input.observedOn,
      p_note: input.note ?? null,
      p_tax_rate_override: input.taxRateOverride ?? null,
    })
    if (error) throw error
    await fetchSuppliers()
    return data as PurchasePrice
  }

  async function deletePurchasePrice(id: string) {
    const supabase = useSupabaseClient()
    const { error } = await supabase.from('product_purchase_prices').delete().eq('id', id)
    if (error) throw error
  }

  async function fetchSummaries(productIds: string[]): Promise<Record<string, PurchaseSummary>> {
    if (productIds.length === 0) return {}
    const supabase = useSupabaseClient()
    const { data, error } = await supabase.rpc('get_product_purchase_summary', { p_product_ids: productIds })
    if (error) throw error
    const map: Record<string, PurchaseSummary> = {}
    for (const r of (data ?? []) as any[]) {
      map[r.product_id] = {
        product_id: r.product_id,
        ek_count: Number(r.ek_count),
        newest_net: r.newest_net == null ? null : Number(r.newest_net),
        newest_gross: r.newest_gross == null ? null : Number(r.newest_gross),
        newest_supplier: r.newest_supplier ?? null,
        newest_on: r.newest_on ?? null,
        min_gross: r.min_gross == null ? null : Number(r.min_gross),
        min_supplier: r.min_supplier ?? null,
        min_on: r.min_on ?? null,
        max_gross: r.max_gross == null ? null : Number(r.max_gross),
        effective_tax_rate: r.effective_tax_rate == null ? null : Number(r.effective_tax_rate),
      }
    }
    return map
  }

  return {
    suppliers,
    fetchSuppliers,
    fetchPurchasePrices,
    resolveTaxRate,
    addPurchasePrice,
    updatePurchasePrice,
    deletePurchasePrice,
    fetchSummaries,
  }
}
```

- [ ] **Step 2: Type-check**

Run:
```bash
cd management-frontend && npx nuxi typecheck 2>&1 | tail -20; cd ..
```
Expected: no NEW type errors referencing `usePurchasePrices.ts` or `purchaseComparison.ts`. (Pre-existing repo type errors, if any, are out of scope — confirm none are newly introduced by these two files.)

- [ ] **Step 3: Commit**

```bash
git add management-frontend/app/composables/usePurchasePrices.ts
git commit -m "feat(pwa): usePurchasePrices composable (suppliers, prices, summaries)"
```

---

## Chunk 4: PWA — product-side UI (EK section + margin + list column)

Adds the supplier autocomplete, the purchase-price section (history + add/edit + margin) as a focused component, wires it into the product modal (edit mode, admin only), and adds an "üblicher EK / Spanne" column to the product list. i18n keys for German + English.

**Files:**
- Create: `management-frontend/app/components/SupplierCombobox.vue`
- Create: `management-frontend/app/components/PurchasePricesSection.vue`
- Modify: `management-frontend/app/components/ProductFormModal.vue` (render the section in edit mode)
- Modify: `management-frontend/app/pages/products/index.vue` (EK/Spanne column)
- Modify: `management-frontend/i18n/locales/de.json` + `management-frontend/i18n/locales/en.json`

### Task 4.1: SupplierCombobox component (free-text + autocomplete)

Modeled exactly on `app/components/ProductCombobox.vue` (reka-ui Command + Popover), but the model is the supplier **name string**; the create item's `value` equals the query so reka never filters it out.

- [ ] **Step 1: Write the component**

Create `management-frontend/app/components/SupplierCombobox.vue`:

```vue
<script setup lang="ts">
import { ref } from 'vue'
import { Check, ChevronsUpDown, Plus } from 'lucide-vue-next'
import {
  Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList,
} from '@/components/ui/command'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { cn } from '@/lib/utils'

const { t } = useI18n()

interface Supplier { id: string; name: string }

const props = withDefaults(
  defineProps<{ modelValue: string; suppliers: Supplier[]; placeholder?: string; disabled?: boolean }>(),
  { placeholder: '', disabled: false },
)
const emit = defineEmits<{ 'update:modelValue': [name: string] }>()

const open = ref(false)
const searchQuery = ref('')

function pick(name: string) {
  emit('update:modelValue', name)
  open.value = false
}
</script>

<template>
  <Popover v-model:open="open">
    <PopoverTrigger as-child>
      <button
        type="button"
        role="combobox"
        :aria-expanded="open"
        :disabled="disabled"
        :class="cn('flex h-9 w-full items-center justify-between rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm hover:bg-accent hover:text-accent-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50')"
      >
        <span class="truncate" :class="{ 'text-muted-foreground': !modelValue }">{{ modelValue || placeholder }}</span>
        <ChevronsUpDown class="ml-2 size-4 shrink-0 opacity-50" />
      </button>
    </PopoverTrigger>
    <PopoverContent class="w-[--reka-popover-trigger-width] p-0" align="start">
      <Command v-model:search-term="searchQuery">
        <CommandInput :placeholder="placeholder" />
        <CommandList>
          <CommandEmpty>
            <span class="text-muted-foreground text-sm">{{ t('common.noResults') }}</span>
          </CommandEmpty>
          <CommandGroup>
            <CommandItem v-for="s in suppliers" :key="s.id" :value="s.name" @select="pick(s.name)">
              <Check :class="cn('mr-2 size-4', modelValue === s.name ? 'opacity-100' : 'opacity-0')" />
              {{ s.name }}
            </CommandItem>
          </CommandGroup>
          <CommandGroup v-if="searchQuery.trim()">
            <CommandItem :value="searchQuery" @select="pick(searchQuery.trim())">
              <Plus class="mr-2 size-4" />
              {{ t('purchasePrices.useSupplier', { name: searchQuery.trim() }) }}
            </CommandItem>
          </CommandGroup>
        </CommandList>
      </Command>
    </PopoverContent>
  </Popover>
</template>
```

- [ ] **Step 2: Commit**

```bash
git add management-frontend/app/components/SupplierCombobox.vue
git commit -m "feat(pwa): SupplierCombobox (name autocomplete + inline create)"
```

### Task 4.2: PurchasePricesSection component

Encapsulates the whole EK UI (history list with cheapest ★ / newest "üblich", add/edit form with net/gross toggle + live counterpart, fallback tax-% field, margin readout). Uses `usePurchasePrices` + `purchaseComparison`.

- [ ] **Step 1: Write the component**

Create `management-frontend/app/components/PurchasePricesSection.vue`:

```vue
<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { formatCurrency } from '@/lib/utils'
import { usePurchasePrices, type PurchasePrice } from '~/composables/usePurchasePrices'
import { counterpart, marginNet } from '~/lib/purchaseComparison'

const props = defineProps<{ productId: string; sellprice: number | null }>()
const { t, locale } = useI18n()
const { suppliers, fetchSuppliers, fetchPurchasePrices, resolveTaxRate, addPurchasePrice, updatePurchasePrice, deletePurchasePrice } = usePurchasePrices()

const prices = ref<PurchasePrice[]>([])
const loading = ref(false)
const error = ref('')
const resolvedRate = ref<number | null>(null)

const today = () => new Date().toISOString().slice(0, 10)
const form = ref({ supplierName: '', price: null as number | null, basis: 'net' as 'net' | 'gross', observedOn: today(), note: '', taxRatePct: null as number | null })
const editingId = ref<string | null>(null)

const needRateOverride = computed(() => resolvedRate.value == null)
const effectiveRate = computed<number | null>(() =>
  needRateOverride.value ? (form.value.taxRatePct == null ? null : form.value.taxRatePct / 100) : resolvedRate.value,
)
const counterpartText = computed(() => {
  if (form.value.price == null || effectiveRate.value == null) return ''
  const other = counterpart(form.value.price, form.value.basis, effectiveRate.value)
  const label = form.value.basis === 'net' ? t('purchasePrices.gross') : t('purchasePrices.net')
  return `= ${formatCurrency(other, locale.value)} ${label}`
})

const newest = computed(() => prices.value[0] ?? null) // already sorted observed_on desc
const cheapestId = computed(() => {
  if (prices.value.length === 0) return null
  return [...prices.value].sort((a, b) => a.price_gross - b.price_gross)[0]!.id
})
const margin = computed(() =>
  newest.value ? marginNet(props.sellprice, newest.value.price_net, newest.value.tax_rate) : null,
)

async function reload() {
  loading.value = true
  try {
    prices.value = await fetchPurchasePrices(props.productId)
    resolvedRate.value = await resolveTaxRate(props.productId)
  } finally {
    loading.value = false
  }
}

watch(() => props.productId, async () => {
  await Promise.all([fetchSuppliers(), reload()])
  resetForm()
}, { immediate: true })

function resetForm() {
  form.value = { supplierName: '', price: null, basis: 'net', observedOn: today(), note: '', taxRatePct: null }
  editingId.value = null
  error.value = ''
}

function startEdit(p: PurchasePrice) {
  editingId.value = p.id
  form.value = {
    supplierName: p.supplier_name,
    price: p.price_basis === 'net' ? p.price_net : p.price_gross,
    basis: p.price_basis,
    observedOn: p.observed_on,
    note: p.note ?? '',
    taxRatePct: needRateOverride.value ? Number((p.tax_rate * 100).toFixed(2)) : null,
  }
}

async function submit() {
  if (!form.value.supplierName.trim() || form.value.price == null) {
    error.value = t('purchasePrices.supplierAndPriceRequired')
    return
  }
  if (needRateOverride.value && form.value.taxRatePct == null) {
    error.value = t('purchasePrices.taxRateRequired')
    return
  }
  error.value = ''
  const input = {
    productId: props.productId,
    supplierName: form.value.supplierName.trim(),
    price: form.value.price,
    basis: form.value.basis,
    observedOn: form.value.observedOn,
    note: form.value.note.trim() || null,
    taxRateOverride: needRateOverride.value && form.value.taxRatePct != null ? form.value.taxRatePct / 100 : null,
  }
  try {
    if (editingId.value) await updatePurchasePrice(editingId.value, input)
    else await addPurchasePrice(input)
    await reload()
    resetForm()
  } catch (e: any) {
    error.value = e?.message ?? t('purchasePrices.saveFailed')
  }
}

async function remove(id: string) {
  await deletePurchasePrice(id)
  await reload()
  if (editingId.value === id) resetForm()
}
</script>

<template>
  <details class="rounded-md border">
    <summary class="cursor-pointer select-none px-3 py-2 text-sm font-medium">
      {{ t('purchasePrices.title') }} <span class="text-muted-foreground">({{ prices.length }})</span>
    </summary>
    <div class="space-y-3 border-t p-3">
      <!-- History -->
      <div v-if="prices.length" class="space-y-1">
        <div
          v-for="p in prices"
          :key="p.id"
          class="flex items-center gap-2 rounded-md border px-2 py-1 text-xs"
        >
          <span class="w-4 shrink-0">{{ p.id === cheapestId ? '★' : '' }}</span>
          <span class="flex-1 truncate font-medium">
            {{ p.supplier_name }}
            <span v-if="p.id === newest?.id" class="ml-1 text-[10px] text-muted-foreground">{{ t('purchasePrices.usual') }}</span>
          </span>
          <span>{{ formatCurrency(p.price_net, locale) }} {{ t('purchasePrices.net') }}</span>
          <span class="text-muted-foreground">{{ formatCurrency(p.price_gross, locale) }} {{ t('purchasePrices.gross') }}</span>
          <span class="text-muted-foreground">{{ p.observed_on }}</span>
          <button type="button" class="text-primary hover:underline" @click="startEdit(p)">{{ t('common.edit') }}</button>
          <button type="button" class="text-destructive hover:underline" @click="remove(p.id)">{{ t('common.delete') }}</button>
        </div>
      </div>
      <p v-else class="text-xs text-muted-foreground">{{ t('purchasePrices.noPrices') }}</p>

      <!-- Add / edit form -->
      <div class="grid grid-cols-2 gap-2">
        <div class="col-span-2">
          <label class="text-xs text-muted-foreground">{{ t('purchasePrices.supplier') }}</label>
          <SupplierCombobox v-model="form.supplierName" :suppliers="suppliers" :placeholder="t('purchasePrices.supplierPlaceholder')" />
        </div>
        <div>
          <label class="text-xs text-muted-foreground">{{ t('purchasePrices.pricePerUnit') }}</label>
          <input v-model.number="form.price" type="number" step="0.0001" min="0" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm" />
        </div>
        <div>
          <label class="text-xs text-muted-foreground">{{ t('purchasePrices.basis') }}</label>
          <div class="flex h-9 items-center gap-1">
            <button type="button" :class="['flex-1 rounded-md border text-xs h-9', form.basis === 'net' ? 'bg-primary text-primary-foreground' : '']" @click="form.basis = 'net'">{{ t('purchasePrices.net') }}</button>
            <button type="button" :class="['flex-1 rounded-md border text-xs h-9', form.basis === 'gross' ? 'bg-primary text-primary-foreground' : '']" @click="form.basis = 'gross'">{{ t('purchasePrices.gross') }}</button>
          </div>
        </div>
        <p v-if="counterpartText" class="col-span-2 text-xs text-muted-foreground">{{ counterpartText }}</p>
        <div v-if="needRateOverride" class="col-span-2">
          <label class="text-xs text-amber-600">{{ t('purchasePrices.taxRateField') }}</label>
          <input v-model.number="form.taxRatePct" type="number" step="0.1" min="0" placeholder="19" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm" />
        </div>
        <div>
          <label class="text-xs text-muted-foreground">{{ t('purchasePrices.date') }}</label>
          <input v-model="form.observedOn" type="date" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm" />
        </div>
        <div>
          <label class="text-xs text-muted-foreground">{{ t('purchasePrices.note') }}</label>
          <input v-model="form.note" type="text" class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm" />
        </div>
      </div>
      <FormError :message="error" />
      <div class="flex gap-2">
        <button v-if="editingId" type="button" class="h-8 flex-1 rounded-md border text-xs" @click="resetForm">{{ t('common.cancel') }}</button>
        <button type="button" class="h-8 flex-1 rounded-md bg-primary text-xs text-primary-foreground" @click="submit">
          {{ editingId ? t('common.save') : t('common.add') }}
        </button>
      </div>

      <!-- Margin -->
      <p v-if="margin" class="text-xs">
        <strong>{{ t('purchasePrices.margin') }}:</strong>
        {{ formatCurrency(margin.rohertrag, locale) }} · {{ margin.spannePct.toFixed(0) }}%
        <span class="text-muted-foreground">({{ t('purchasePrices.marginHint') }})</span>
      </p>
    </div>
  </details>
</template>
```

- [ ] **Step 2: Commit**

```bash
git add management-frontend/app/components/PurchasePricesSection.vue
git commit -m "feat(pwa): PurchasePricesSection (history, add/edit, net/gross, margin)"
```

### Task 4.3: Wire the section into ProductFormModal (edit mode, admin)

- [ ] **Step 1: Add the section after the barcodes block**

In `management-frontend/app/components/ProductFormModal.vue`, immediately AFTER the closing `</div>` of the barcodes block (the `<div v-if="isAdmin" class="space-y-2">` that ends right before `<!-- Barcode Scanner overlay -->`, around line 419) and BEFORE the `<!-- Barcode Scanner overlay -->` comment, insert:

```vue
      <!-- Purchase prices (edit mode, admin only) -->
      <PurchasePricesSection
        v-if="isAdmin && editingProduct"
        :product-id="editingProduct.id"
        :sellprice="productForm.sellprice"
      />
```

- [ ] **Step 2: Verify in the running app**

Use the preview workflow (preview_start if needed). Open a product (admin) → the "Einkaufspreise" disclosure appears; add a net price → the live "= … brutto" hint updates; save → it appears in the history with ★ on the cheapest; margin line shows. Confirm no console errors (preview_console_logs).

- [ ] **Step 3: Commit**

```bash
git add management-frontend/app/components/ProductFormModal.vue
git commit -m "feat(pwa): show PurchasePricesSection in product edit modal"
```

### Task 4.4: EK / Spanne column in the product list

- [ ] **Step 1: Add summary loading + column to `pages/products/index.vue`**

In the `<script setup>` add (near the other composable usage):

```ts
import { marginNet, type PurchaseSummary } from '~/lib/purchaseComparison'
const { fetchSummaries } = usePurchasePrices()
const ekSummaries = ref<Record<string, PurchaseSummary>>({})

async function loadEkSummaries() {
  const ids = products.value.map(p => p.id)
  ekSummaries.value = await fetchSummaries(ids)
}
```

Extend the sort key union and comparator:
```ts
const { sortKey: prodSortKey, sortDir: prodSortDir, toggleSort: toggleProdSort, sortIcon: prodSortIcon } = useTableSort<'name' | 'category' | 'price' | 'ek'>('name')
```
In `sortedProducts`'s `.sort(...)`, before the final `return dir * (...)`, add:
```ts
    if (prodSortKey.value === 'ek') {
      const ag = ekSummaries.value[a.id]?.newest_gross ?? -1
      const bg = ekSummaries.value[b.id]?.newest_gross ?? -1
      return dir * (ag - bg)
    }
```
Call `loadEkSummaries()` after products load — extend the `onMounted` Promise.all to `.then(loadEkSummaries)`, and call it in `onProductSaved` after `fetchProducts()`.

- [ ] **Step 2: Add the column to the products table**

In the `<thead>` after the price `<th>` (line ~254), add:
```vue
                    <th class="hidden md:table-cell px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleProdSort('ek')">
                      <SortHeader :icon="prodSortIcon('ek')" align="right">{{ t('purchasePrices.ekColumn') }}</SortHeader>
                    </th>
```
In each `<tr>`, after the price `<td>` (line ~296), add:
```vue
                    <td class="hidden md:table-cell px-4 py-3 text-right text-xs">
                      <template v-if="ekSummaries[product.id]?.newest_gross != null">
                        {{ formatCurrency(ekSummaries[product.id]!.newest_gross!, locale) }}
                        <span v-if="marginNet(product.sellprice, ekSummaries[product.id]!.newest_net, ekSummaries[product.id]!.effective_tax_rate)" class="block text-muted-foreground">
                          {{ marginNet(product.sellprice, ekSummaries[product.id]!.newest_net, ekSummaries[product.id]!.effective_tax_rate)!.spannePct.toFixed(0) }}%
                        </span>
                      </template>
                      <span v-else class="text-muted-foreground">—</span>
                    </td>
```

- [ ] **Step 3: Verify in the running app**

Reload `/products`. Products with recorded EK show "üblicher EK" gross + Spanne %; others show "—". Clicking the EK header sorts. No console errors.

- [ ] **Step 4: Commit**

```bash
git add management-frontend/app/pages/products/index.vue
git commit -m "feat(pwa): EK/margin column in product list"
```

### Task 4.5: i18n keys (de + en)

- [ ] **Step 1: Add the `purchasePrices` block to both locale files**

Merge into `management-frontend/i18n/locales/de.json` (top-level key, following the existing nested-object structure):
```json
"purchasePrices": {
  "title": "Einkaufspreise",
  "supplier": "Lieferant",
  "supplierPlaceholder": "Lieferant suchen oder anlegen …",
  "useSupplier": "„{name}“ verwenden",
  "pricePerUnit": "Preis je Stück",
  "basis": "Basis",
  "net": "netto",
  "gross": "brutto",
  "date": "Datum",
  "note": "Notiz",
  "noPrices": "Noch keine Einkaufspreise erfasst.",
  "taxRateField": "Steuersatz % (kein Satz am Produkt hinterlegt)",
  "taxRateRequired": "Bitte einen Steuersatz angeben.",
  "supplierAndPriceRequired": "Lieferant und Preis sind erforderlich.",
  "margin": "Marge",
  "marginHint": "VK netto − üblicher EK netto",
  "usual": "üblich",
  "saveFailed": "Speichern fehlgeschlagen.",
  "ekColumn": "üblicher EK"
}
```
And the English equivalents into `management-frontend/i18n/locales/en.json`:
```json
"purchasePrices": {
  "title": "Purchase prices",
  "supplier": "Supplier",
  "supplierPlaceholder": "Search or add a supplier …",
  "useSupplier": "Use \"{name}\"",
  "pricePerUnit": "Price per unit",
  "basis": "Basis",
  "net": "net",
  "gross": "gross",
  "date": "Date",
  "note": "Note",
  "noPrices": "No purchase prices recorded yet.",
  "taxRateField": "Tax rate % (no rate set on the product)",
  "taxRateRequired": "Please provide a tax rate.",
  "supplierAndPriceRequired": "Supplier and price are required.",
  "margin": "Margin",
  "marginHint": "net sell price − usual net purchase price",
  "usual": "usual",
  "saveFailed": "Save failed.",
  "ekColumn": "usual cost"
}
```

- [ ] **Step 2: Verify both JSON files parse**

Run:
```bash
cd management-frontend && node -e "JSON.parse(require('fs').readFileSync('i18n/locales/de.json','utf8')); JSON.parse(require('fs').readFileSync('i18n/locales/en.json','utf8')); console.log('ok')"; cd ..
```
Expected: `ok`. Reload the app and confirm no missing-key warnings for `purchasePrices.*`.

- [ ] **Step 3: Commit**

```bash
git add management-frontend/i18n/locales/de.json management-frontend/i18n/locales/en.json
git commit -m "i18n(pwa): purchase-price + supplier strings (de/en)"
```

---

## Chunk 5: PWA — deals comparison + suppression UI

Wires EK summaries into `useDeals`, computes per-deal verdicts + the card-suppression rollup (mirroring the server rule), and renders the pill, detail comparison, and the "N ausgeblendet" disclosure. The grid switches from `activeDeals` to the suppressed-free `visibleActiveDeals`.

**Files:**
- Modify: `management-frontend/app/composables/useDeals.ts`
- Modify: `management-frontend/app/pages/deals/index.vue`
- Modify: `management-frontend/i18n/locales/de.json` + `en.json`

### Task 5.1: Add EK comparison + suppression to `useDeals`

- [ ] **Step 1: Add the import** (top of `useDeals.ts`, before the `export interface DealKeyword` line):

```ts
import { classifyDeal, isCardSuppressed, type DealVerdict, type PurchaseSummary } from '~/lib/purchaseComparison'
```

- [ ] **Step 2: Add EK state + helpers** inside `useDeals()`, immediately after `const { organization } = useOrganization()` (line ~172):

```ts
  // ── EK (purchase-price) comparison ───────────────────────────────────────
  const { fetchSummaries } = usePurchasePrices()
  const ekSummaries = ref<Record<string, PurchaseSummary>>({})

  /** All catalog product ids an offer matched (name matches + keyword-group products). */
  function dealProductIds(d: DedupedDeal): string[] {
    const ids = new Set<string>()
    for (const p of d.matchedProducts) ids.add(p.id)
    for (const k of d.matchedKeywords) for (const p of k.products) ids.add(p.id)
    return [...ids]
  }

  /** Fetch EK summaries for every product referenced by the current deal set. */
  async function fetchEkSummaries() {
    const ids = new Set<string>()
    for (const d of deals.value) {
      if (d.products?.id) ids.add(d.products.id)
      for (const kp of d.deal_keywords?.deal_keyword_products ?? []) {
        if (kp.products?.id) ids.add(kp.products.id)
      }
    }
    ekSummaries.value = await fetchSummaries([...ids])
  }

  const VERDICT_RANK: Record<DealVerdict, number> = {
    good_best: 5, good: 4, similar: 3, worse: 2, no_ek: 1, implausible: 0,
  }

  /** Per-deal EK comparison: per-product verdicts, card-suppression flag, best verdict for the pill. */
  function dealEk(d: DedupedDeal) {
    const dealGross = d.primary.deal_price
    const perProduct = dealProductIds(d).map((id) => ({
      productId: id,
      summary: ekSummaries.value[id] ?? null,
      ...classifyDeal(dealGross, ekSummaries.value[id]),
    }))
    const verdicts = perProduct.map((p) => p.verdict)
    const suppressed = isCardSuppressed(verdicts)
    const ranked = verdicts.filter((v) => v !== 'no_ek').sort((a, b) => VERDICT_RANK[b] - VERDICT_RANK[a])
    const bestVerdict = ranked[0] ?? null
    return { perProduct, suppressed, bestVerdict }
  }
```

- [ ] **Step 3: Add visible/suppressed computeds** immediately after the `activeDeals` computed (after line ~566):

```ts
  const suppressedKeys = computed(() => {
    const s = new Set<string>()
    for (const d of activeDeals.value) if (dealEk(d).suppressed) s.add(d.key)
    return s
  })
  // Grid shows these; suppressed (deal > highest recorded EK → likely mismatch) are hidden.
  const visibleActiveDeals = computed(() => activeDeals.value.filter((d) => !suppressedKeys.value.has(d.key)))
  const suppressedActiveDeals = computed(() => activeDeals.value.filter((d) => suppressedKeys.value.has(d.key)))
```

- [ ] **Step 4: Re-base the on-screen stats** so numbers match the visible grid. Replace the four computeds at lines ~595–609 (`totalDeals`, `uniqueRetailers`, `avgDiscount`, `newDealsCount`) — swap `activeDeals.value` → `visibleActiveDeals.value` in each:

```ts
  const totalDeals = computed(() => visibleActiveDeals.value.length)
  const uniqueRetailers = computed(() => new Set(visibleActiveDeals.value.map((d) => d.retailer)).size)
  const avgDiscount = computed(() => {
    const withDiscount = visibleActiveDeals.value.filter(
      (d) => d.primary.discount_pct != null && d.primary.discount_pct > 0,
    )
    if (withDiscount.length === 0) return 0
    return Math.round(
      withDiscount.reduce((sum, d) => sum + (d.primary.discount_pct ?? 0), 0) / withDiscount.length,
    )
  })
  // ... (archivedCount unchanged) ...
  const newDealsCount = computed(() => visibleActiveDeals.value.filter(isNew).length)
```

(`isNew` already excludes suppressed via the server-cleaned `newDealKeys`; basing the count on `visibleActiveDeals` makes it doubly correct and consistent with the grid.)

- [ ] **Step 5: Export the new members** — add to the `return { … }` object:

```ts
    ekSummaries,
    fetchEkSummaries,
    dealEk,
    visibleActiveDeals,
    suppressedActiveDeals,
```

- [ ] **Step 6: Type-check**

Run:
```bash
cd management-frontend && npx nuxi typecheck 2>&1 | grep -E "useDeals|purchaseComparison" || echo "no new errors in useDeals"; cd ..
```
Expected: `no new errors in useDeals`.

- [ ] **Step 7: Commit**

```bash
git add management-frontend/app/composables/useDeals.ts
git commit -m "feat(pwa): deals EK comparison + card suppression in useDeals"
```

### Task 5.2: Render comparison + suppression in `deals/index.vue`

The detail-sheet matched-product list is `<li v-for="p in selectedDeal.matchedProducts">` (line ~891); the grid source is `const source = … : activeDeals.value` (line ~147); the card deal-price span is at line ~660; `openDetail(deal)` is line ~125; `selectedDeal` ref line ~72. `t` and `locale` come from `useI18n()`.

- [ ] **Step 1: Destructure the new members + add helpers** (in `<script setup>`):

Change the i18n destructure (line ~34) from `const { t } = useI18n()` to `const { t, locale } = useI18n()` (the detail block formats currency with `locale`). Add `visibleActiveDeals, suppressedActiveDeals, ekSummaries, dealEk, fetchEkSummaries` to the existing `useDeals()` destructure (lines ~50–51 area), and add:

```ts
import { classifyDeal, marginDelta, type DealVerdict, type PurchaseSummary } from '~/lib/purchaseComparison'
import { formatCurrency } from '@/lib/utils'

// "+ EK erfassen" modal
const ekModalProductId = ref<string | null>(null)
const ekModalOpen = ref(false)
function openEkModal(productId: string) { ekModalProductId.value = productId; ekModalOpen.value = true }
async function onEkSaved() { await fetchEkSummaries() }

// Card pill: best verdict → { label, cls } or null
function ekPill(deal: DedupedDeal): { label: string; cls: string } | null {
  const ek = dealEk(deal)
  if (!ek.bestVerdict) return null
  const best = ek.perProduct.find((p) => p.verdict === ek.bestVerdict)
  const pct = best?.deltaPct != null ? Math.abs(Math.round(best.deltaPct)) : null
  switch (ek.bestVerdict) {
    case 'good_best':
    case 'good':    return { cls: 'text-green-600 dark:text-green-400', label: pct != null ? t('deals.ekCheaperPct', { pct }) : t('deals.ekCheaper') }
    case 'similar': return { cls: 'text-amber-600 dark:text-amber-400', label: t('deals.ekSimilar') }
    case 'worse':   return { cls: 'text-red-600 dark:text-red-400', label: pct != null ? t('deals.ekWorsePct', { pct }) : t('deals.ekWorse') }
    default:        return null
  }
}

// Detail: per-product comparison for the selected deal — computed ONCE per render,
// keyed by product id (avoids re-running classifyDeal repeatedly in the template).
const detailComparisons = computed<Record<string, { summary: PurchaseSummary | null; verdict: DealVerdict; marginDelta: { currentPct: number; dealPct: number } | null }>>(() => {
  const out: Record<string, { summary: PurchaseSummary | null; verdict: DealVerdict; marginDelta: { currentPct: number; dealPct: number } | null }> = {}
  const d = selectedDeal.value
  if (!d) return out
  const dealGross = d.primary.deal_price
  for (const p of d.matchedProducts) {
    const summary = ekSummaries.value[p.id] ?? null
    const cmp = classifyDeal(dealGross, summary)
    const md = (cmp.verdict === 'good' || cmp.verdict === 'good_best') && dealGross != null && summary
      ? marginDelta(p.sellprice, dealGross, summary)
      : null
    out[p.id] = { summary, verdict: cmp.verdict, marginDelta: md }
  }
  return out
})
```

- [ ] **Step 2: Grid uses `visibleActiveDeals`** — change line ~147:

```ts
  const source = listMode.value === 'archived' ? archivedDeals.value : visibleActiveDeals.value
```

- [ ] **Step 3: Fetch EK summaries after deals load** — find where `fetchDeals()` is awaited (onMounted / refresh handler) and chain `await fetchEkSummaries()` right after it (so `ekSummaries` is populated before the grid computes verdicts). Do the same after a forced refresh.

- [ ] **Step 4: Add the pill to the card** — immediately after the deal-price `</span>` (line ~662), inside the same price row container:

```vue
                        <span v-if="ekPill(deal)" :class="ekPill(deal)!.cls" class="ml-2 text-xs font-medium">
                          {{ ekPill(deal)!.label }}
                        </span>
```

- [ ] **Step 5: Add the comparison block to the detail matched-product `<li>`** — inside `<li v-for="p in selectedDeal.matchedProducts">` (line ~891), after the existing name/price/stock content, append:

```vue
                <div class="mt-1 w-full text-xs">
                  <template v-if="detailComparisons[p.id]?.summary?.ek_count">
                    <span class="text-muted-foreground">
                      {{ t('deals.ekVsUsual', {
                        deal: formatCurrency(selectedDeal.primary.deal_price ?? 0, locale),
                        ek: formatCurrency(detailComparisons[p.id]!.summary!.newest_gross ?? 0, locale),
                      }) }}
                    </span>
                    <span v-if="detailComparisons[p.id]?.marginDelta" class="block text-muted-foreground">
                      {{ t('deals.ekMarginEffect', {
                        from: detailComparisons[p.id]!.marginDelta!.currentPct.toFixed(0),
                        to: detailComparisons[p.id]!.marginDelta!.dealPct.toFixed(0),
                      }) }}
                    </span>
                  </template>
                  <button v-else type="button" class="text-primary hover:underline" @click.stop="openEkModal(p.id)">
                    {{ t('deals.ekNone') }} · {{ t('deals.ekAdd') }}
                  </button>
                </div>
```

- [ ] **Step 6: Add the suppressed disclosure** — the card grid (`<div class="grid …">` at line ~551) is **inside** the `v-for="group in groupedFiltered"` loop, whose wrapper `<div v-else class="space-y-6">` closes at line ~692. Place the disclosure **after that wrapper's closing `</div>` (line ~692), immediately before `</TabsContent>`**, so it renders **once** (not per retailer group):

```vue
          <details v-if="listMode !== 'archived' && suppressedActiveDeals.length" class="mt-4 rounded-md border px-3 py-2 text-sm">
            <summary class="cursor-pointer select-none text-muted-foreground">
              {{ t('deals.ekHiddenCount', { n: suppressedActiveDeals.length }) }} · {{ t('deals.ekShow') }}
            </summary>
            <ul class="mt-2 space-y-1">
              <li v-for="deal in suppressedActiveDeals" :key="deal.key" class="flex items-center gap-2">
                <span class="flex-1 truncate">{{ deal.primary.deal_title }} · {{ deal.retailer }}</span>
                <span class="text-red-600 dark:text-red-400">{{ t('deals.ekLikelyMismatch') }}</span>
                <button type="button" class="text-primary hover:underline" @click="openDetail(deal)">{{ t('common.details') }}</button>
              </li>
            </ul>
          </details>
```

- [ ] **Step 7: Add the EK modal** — near the existing detail `<Sheet>` (end of template), add:

```vue
      <ProductFormModal v-model:open="ekModalOpen" :product-id="ekModalProductId" @saved="onEkSaved" />
```

- [ ] **Step 8: Verify in the running app**

Use the preview workflow. With a product that has an EK below a matched deal's price → card shows a green/amber/red pill; detail shows "Angebot … vs üblicher EK …" and (green case) the margin-effect line. With a product whose recorded EK is far below the deal price (deal > max EK) → the deal is absent from the grid and appears under "N ausgeblendet" → expand → "evtl. Fehl-Match". A matched product without EK shows "Kein EK · EK erfassen" → clicking opens the product modal; saving refreshes the comparison. Check `preview_console_logs` for errors.

- [ ] **Step 9: Commit**

```bash
git add management-frontend/app/pages/deals/index.vue
git commit -m "feat(pwa): deal EK comparison pill, detail comparison, suppressed section"
```

### Task 5.3: i18n keys for deals comparison (de + en)

- [ ] **Step 1: Merge into the existing `deals` object** in both locale files.

`de.json` (add inside the existing `"deals": { … }` object):
```json
"ekCheaperPct": "{pct}% günstiger als dein EK",
"ekCheaper": "günstiger als dein EK",
"ekSimilar": "≈ wie dein EK",
"ekWorsePct": "{pct}% über deinem EK",
"ekWorse": "teurer als dein EK",
"ekVsUsual": "Angebot {deal} vs. üblicher EK {ek}",
"ekMarginEffect": "Spanne {from}% → {to}%",
"ekNone": "Kein EK hinterlegt",
"ekAdd": "EK erfassen",
"ekHiddenCount": "{n} ausgeblendet — über deinem höchsten EK",
"ekShow": "anzeigen",
"ekLikelyMismatch": "evtl. Fehl-Match"
```

`en.json` (inside `"deals"`):
```json
"ekCheaperPct": "{pct}% below your cost",
"ekCheaper": "below your cost",
"ekSimilar": "≈ your cost",
"ekWorsePct": "{pct}% above your cost",
"ekWorse": "above your cost",
"ekVsUsual": "Offer {deal} vs usual cost {ek}",
"ekMarginEffect": "Margin {from}% → {to}%",
"ekNone": "No cost recorded",
"ekAdd": "add cost",
"ekHiddenCount": "{n} hidden — above your highest cost",
"ekShow": "show",
"ekLikelyMismatch": "likely mismatch"
```

Also confirm `common.details` exists in both (used by the suppressed list); if not, add `"details": "Details"` to `common`.

- [ ] **Step 2: Validate JSON**

Run:
```bash
cd management-frontend && node -e "JSON.parse(require('fs').readFileSync('i18n/locales/de.json','utf8'));JSON.parse(require('fs').readFileSync('i18n/locales/en.json','utf8'));console.log('ok')"; cd ..
```
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add management-frontend/i18n/locales/de.json management-frontend/i18n/locales/en.json
git commit -m "i18n(pwa): deal EK comparison strings (de/en)"
```

---

## Chunk 6: iOS — models, comparison port, view-model logic

Native parity, logic layer. Pure `PurchaseComparison.swift` is a 1:1 port of `purchaseComparison.ts` (same thresholds). The iOS project has **no unit-test target**, so the TS Vitest suite (Chunk 3) is the parity guard; iOS verification is "builds clean + matches the TS cases by inspection". RPC/table calls follow the existing `ProductsViewModel`/`DealsViewModel` idioms (`SupabaseService.shared.client`, `[String: AnyJSON]` params, snake_case `CodingKeys`).

**Files:**
- Create: `ios/VMflow/Models/Supplier.swift`, `ios/VMflow/Models/PurchasePrice.swift`, `ios/VMflow/Models/ProductPurchaseSummary.swift`
- Create: `ios/VMflow/Utilities/PurchaseComparison.swift`
- Create: `ios/VMflow/ViewModels/PurchasePricesViewModel.swift`
- Modify: `ios/VMflow/ViewModels/DealsViewModel.swift`

> **Xcode project membership:** new `.swift` files must be added to the `VMflow` target in `VMflow.xcodeproj` (drag into the matching group in Xcode, or they won't compile). Call this out — CLI file creation alone does not register them with the target.

### Task 6.1: Model structs

- [ ] **Step 1: Write the three model files**

`ios/VMflow/Models/Supplier.swift`:
```swift
import Foundation

/// A supplier (Lieferant). Maps to the `suppliers` table.
struct Supplier: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
}
```

`ios/VMflow/Models/ProductPurchaseSummary.swift`:
```swift
import Foundation

/// Per-product purchase-price aggregates from the get_product_purchase_summary RPC.
struct ProductPurchaseSummary: Codable, Identifiable {
    let productId: UUID
    let ekCount: Int
    let newestNet: Double?
    let newestGross: Double?
    let newestSupplier: String?
    let newestOn: String?
    let minGross: Double?
    let minSupplier: String?
    let minOn: String?
    let maxGross: Double?
    let effectiveTaxRate: Double?

    var id: UUID { productId }

    enum CodingKeys: String, CodingKey {
        case productId = "product_id"
        case ekCount = "ek_count"
        case newestNet = "newest_net"
        case newestGross = "newest_gross"
        case newestSupplier = "newest_supplier"
        case newestOn = "newest_on"
        case minGross = "min_gross"
        case minSupplier = "min_supplier"
        case minOn = "min_on"
        case maxGross = "max_gross"
        case effectiveTaxRate = "effective_tax_rate"
    }
}
```

`ios/VMflow/Models/PurchasePrice.swift`:
```swift
import Foundation

/// One recorded purchase price. The `suppliers(name)` nested join is decoded
/// via the `suppliers` relation and surfaced through `supplierName`.
struct PurchasePrice: Codable, Identifiable {
    let id: UUID
    let productId: UUID
    let supplierId: UUID
    let priceNet: Double
    let priceGross: Double
    let priceBasis: String   // "net" | "gross"
    let taxRate: Double
    let observedOn: String
    let note: String?
    let suppliers: SupplierName?

    var supplierName: String { suppliers?.name ?? "" }

    struct SupplierName: Codable { let name: String }

    enum CodingKeys: String, CodingKey {
        case id, suppliers, note
        case productId = "product_id"
        case supplierId = "supplier_id"
        case priceNet = "price_net"
        case priceGross = "price_gross"
        case priceBasis = "price_basis"
        case taxRate = "tax_rate"
        case observedOn = "observed_on"
    }
}
```

- [ ] **Step 2: Add all three files to the VMflow target in Xcode, then commit**

```bash
git add ios/VMflow/Models/Supplier.swift ios/VMflow/Models/PurchasePrice.swift ios/VMflow/Models/ProductPurchaseSummary.swift ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): Supplier / PurchasePrice / ProductPurchaseSummary models"
```

### Task 6.2: PurchaseComparison (pure port of the TS module)

- [ ] **Step 1: Write the file** — must match `management-frontend/app/lib/purchaseComparison.ts` thresholds exactly.

`ios/VMflow/Utilities/PurchaseComparison.swift`:
```swift
import Foundation

enum PriceBasis: String { case net, gross }

enum DealVerdict: String { case noEk, implausible, goodBest, good, similar, worse }

struct DealComparison {
    let verdict: DealVerdict
    let deltaPct: Double?   // vs newest (üblicher) gross; negative = cheaper
}

/// Pure purchase-price comparison logic. 1:1 port of purchaseComparison.ts —
/// keep both in sync. (TS Vitest suite is the shared parity guard.)
enum PurchaseComparison {
    static func round4(_ n: Double) -> Double { (n * 10000).rounded() / 10000 }

    static func counterpart(_ value: Double, basis: PriceBasis, rate: Double) -> Double {
        basis == .net ? round4(value * (1 + rate)) : round4(value / (1 + rate))
    }

    /// Net-basis margin VK_net − EK_net. Nil if inputs missing or VK_net ≤ 0.
    static func marginNet(sellpriceGross: Double?, ekNet: Double?, rate: Double?) -> (rohertrag: Double, spannePct: Double)? {
        guard let s = sellpriceGross, let ek = ekNet, let r = rate else { return nil }
        let vkNet = s / (1 + r)
        guard vkNet > 0 else { return nil }
        let rohertrag = vkNet - ek
        return (rohertrag, (rohertrag / vkNet) * 100)
    }

    static func classifyDeal(dealGross: Double?, summary: ProductPurchaseSummary?, tolerancePct: Double = 3) -> DealComparison {
        guard let dg = dealGross, let s = summary, s.ekCount > 0,
              let maxG = s.maxGross, let newest = s.newestGross else {
            return DealComparison(verdict: .noEk, deltaPct: nil)
        }
        let deltaPct = ((dg - newest) / newest) * 100
        if dg > maxG { return DealComparison(verdict: .implausible, deltaPct: deltaPct) }
        if let minG = s.minGross, dg <= minG { return DealComparison(verdict: .goodBest, deltaPct: deltaPct) }
        if dg < newest && abs(deltaPct) > tolerancePct { return DealComparison(verdict: .good, deltaPct: deltaPct) }
        if abs(deltaPct) <= tolerancePct { return DealComparison(verdict: .similar, deltaPct: deltaPct) }
        return DealComparison(verdict: .worse, deltaPct: deltaPct)
    }

    /// Margin if the deal replaced the usual EK (green-case display). Nil if not computable.
    static func marginDelta(sellpriceGross: Double?, dealGross: Double, summary: ProductPurchaseSummary) -> (currentPct: Double, dealPct: Double)? {
        guard let s = sellpriceGross, let rate = summary.effectiveTaxRate, let newestNet = summary.newestNet else { return nil }
        let vkNet = s / (1 + rate)
        guard vkNet > 0 else { return nil }
        let dealNet = dealGross / (1 + rate)
        return (((vkNet - newestNet) / vkNet) * 100, ((vkNet - dealNet) / vkNet) * 100)
    }

    /// A deal card is suppressed iff it has matched products and ALL are implausible.
    static func isCardSuppressed(_ verdicts: [DealVerdict]) -> Bool {
        !verdicts.isEmpty && verdicts.allSatisfy { $0 == .implausible }
    }
}
```

- [ ] **Step 2: Add to the VMflow target + commit**

```bash
git add ios/VMflow/Utilities/PurchaseComparison.swift ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): PurchaseComparison (pure port of purchaseComparison.ts)"
```

### Task 6.3: PurchasePricesViewModel

- [ ] **Step 1: Write the view-model** — RPC/table idioms mirror `ProductsViewModel`.

`ios/VMflow/ViewModels/PurchasePricesViewModel.swift`:
```swift
import Foundation
import Supabase

@MainActor
final class PurchasePricesViewModel: ObservableObject {
    @Published var suppliers: [Supplier] = []
    @Published var prices: [PurchasePrice] = []
    @Published var resolvedRate: Double? = nil
    @Published var isLoading = false
    @Published var error: String?

    private let client = SupabaseService.shared.client

    func loadSuppliers() async {
        do {
            suppliers = try await client.from("suppliers")
                .select("id, name").order("name", ascending: true).execute().value
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    func loadPrices(productId: UUID) async {
        isLoading = true; defer { isLoading = false }
        do {
            prices = try await client.from("product_purchase_prices")
                .select("id, product_id, supplier_id, price_net, price_gross, price_basis, tax_rate, observed_on, note, suppliers(name)")
                .eq("product_id", value: productId.uuidString)
                .order("observed_on", ascending: false)
                .order("created_at", ascending: false)
                .execute().value
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    /// Resolves the product's effective tax rate (nil → caller must supply an override %).
    func resolveTaxRate(productId: UUID) async {
        do {
            resolvedRate = try await client
                .rpc("resolve_product_tax_rate", params: ["p_product_id": .string(productId.uuidString)])
                .execute().value
        } catch { resolvedRate = nil }
    }

    @discardableResult
    func addPrice(productId: UUID, supplierName: String, price: Double, basis: String,
                  observedOn: String, note: String?, taxRateOverride: Double?) async -> Bool {
        do {
            let params: [String: AnyJSON] = [
                "p_product_id": .string(productId.uuidString),
                "p_supplier_name": .string(supplierName),
                "p_price": .double(price),
                "p_basis": .string(basis),
                "p_observed_on": .string(observedOn),
                "p_note": note.map { AnyJSON.string($0) } ?? .null,
                "p_tax_rate_override": taxRateOverride.map { AnyJSON.double($0) } ?? .null,
            ]
            try await client.rpc("add_purchase_price", params: params).execute()
            await loadSuppliers(); await loadPrices(productId: productId)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func updatePrice(id: UUID, productId: UUID, supplierName: String, price: Double, basis: String,
                     observedOn: String, note: String?, taxRateOverride: Double?) async -> Bool {
        do {
            let params: [String: AnyJSON] = [
                "p_id": .string(id.uuidString),
                "p_supplier_name": .string(supplierName),
                "p_price": .double(price),
                "p_basis": .string(basis),
                "p_observed_on": .string(observedOn),
                "p_note": note.map { AnyJSON.string($0) } ?? .null,
                "p_tax_rate_override": taxRateOverride.map { AnyJSON.double($0) } ?? .null,
            ]
            try await client.rpc("update_purchase_price", params: params).execute()
            await loadSuppliers(); await loadPrices(productId: productId)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func deletePrice(id: UUID, productId: UUID) async {
        do {
            try await client.from("product_purchase_prices").delete().eq("id", value: id.uuidString).execute()
            await loadPrices(productId: productId)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    /// Batch summaries for the deals screen / product list.
    func fetchSummaries(productIds: [UUID]) async -> [UUID: ProductPurchaseSummary] {
        guard !productIds.isEmpty else { return [:] }
        do {
            let rows: [ProductPurchaseSummary] = try await client
                .rpc("get_product_purchase_summary",
                     params: ["p_product_ids": .array(productIds.map { AnyJSON.string($0.uuidString) })])
                .execute().value
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.productId, $0) })
        } catch { return [:] }
    }
}
```

- [ ] **Step 2: Add to target + commit**

```bash
git add ios/VMflow/ViewModels/PurchasePricesViewModel.swift ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): PurchasePricesViewModel (suppliers, prices, summaries, RPCs)"
```

### Task 6.4: EK comparison + suppression in DealsViewModel

- [ ] **Step 1: Add EK state + helpers** to `DealsViewModel` (after the `@Published var newDealKeys` line, ~29):

```swift
    /// EK summaries for products referenced by the current deal set (product id → summary).
    @Published var ekSummaries: [UUID: ProductPurchaseSummary] = [:]
    private let purchaseVM = PurchasePricesViewModel()
```

In `loadAll()`, after `await fetchDeals()` (and `fetchNewDealKeys`), add `await fetchEkSummaries()`. Add the method + comparison helpers (anywhere in the class body):

```swift
    /// All catalog product ids an offer references (name matches + keyword-group products).
    private func dealProductIds(_ d: DedupedDeal) -> [UUID] {
        var ids = Set<UUID>()
        for p in d.matchedProducts { ids.insert(p.id) }
        for kw in d.matchedKeywords { for lp in kw.linkedProducts { if let id = lp.id { ids.insert(id) } } }
        return Array(ids)
    }

    // Walks the raw `deals` rows (covers the same products as `dealProductIds`,
    // just from the other shape) — intentional, don't "unify" the two.
    func fetchEkSummaries() async {
        var ids = Set<UUID>()
        for d in deals {
            if let pid = d.productId { ids.insert(pid) }
            for lp in d.dealKeywords?.linkedProducts ?? [] { if let id = lp.id { ids.insert(id) } }
        }
        ekSummaries = await purchaseVM.fetchSummaries(productIds: Array(ids))
    }

    private static let verdictRank: [DealVerdict: Int] = [
        .goodBest: 5, .good: 4, .similar: 3, .worse: 2, .noEk: 1, .implausible: 0,
    ]

    /// Per-deal EK result: card-suppression flag + best verdict (with its delta) for the pill.
    func dealEk(_ d: DedupedDeal) -> (suppressed: Bool, bestVerdict: DealVerdict?, bestDeltaPct: Double?) {
        let dealGross = d.primary.dealPrice
        let comparisons = dealProductIds(d).map {
            PurchaseComparison.classifyDeal(dealGross: dealGross, summary: ekSummaries[$0])
        }
        let verdicts = comparisons.map { $0.verdict }
        let suppressed = PurchaseComparison.isCardSuppressed(verdicts)
        let ranked = comparisons
            .filter { $0.verdict != .noEk }
            .sorted { (Self.verdictRank[$0.verdict] ?? 0) > (Self.verdictRank[$1.verdict] ?? 0) }
        return (suppressed, ranked.first?.verdict, ranked.first?.deltaPct)
    }
```

- [ ] **Step 2: Add visible/suppressed lists + re-base the active source.**

Add:
```swift
    var visibleActiveDeals: [DedupedDeal] { activeDeals.filter { !dealEk($0).suppressed } }
    var suppressedActiveDeals: [DedupedDeal] { activeDeals.filter { dealEk($0).suppressed } }
```
In `filteredDeals`, change the active branch source from `activeDeals` to `visibleActiveDeals`:
```swift
    var filteredDeals: [DedupedDeal] {
        let source = listMode == .archived ? archivedDeals : visibleActiveDeals
        // ... unchanged ...
    }
```
(`totalDeals`/`uniqueRetailers`/`avgDiscount`/`groupedDeals` all derive from `filteredDeals`, so they become suppressed-free automatically. `isNew`/`newDealKeys` already exclude suppressed server-side.)

- [ ] **Step 3: Build the app**

Open `ios/VMflow.xcodeproj` in Xcode and build (⌘B) for an iOS Simulator destination. Expected: build succeeds, no errors. (If `xcodebuild` is available: `xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' build` — but Xcode build is the reliable check.)

- [ ] **Step 4: Commit**

```bash
git add ios/VMflow/ViewModels/DealsViewModel.swift
git commit -m "feat(ios): deals EK comparison + card suppression in DealsViewModel"
```

---

## Chunk 7: iOS — views (EK sheet, product detail, deal card/detail) + localization

The UI layer. New `PurchasePricesSheet` carries the full EK management UI; the rest are anchored edits to existing views. Strings use `String(localized:)` with English as the key; German translations are filled in the String Catalog after a build extracts the keys.

**Files:**
- Create: `ios/VMflow/Views/Products/PurchasePricesSheet.swift`
- Modify: `ios/VMflow/Views/Products/ProductDetailSheet.swift`
- Modify: `ios/VMflow/Views/Deals/DealCard.swift`
- Modify: `ios/VMflow/Views/Deals/DealsView.swift`
- Modify: `ios/VMflow/Views/Deals/DealDetailSheet.swift`
- Modify: `ios/VMflow/Resources/Localizable.xcstrings`

### Task 7.1: PurchasePricesSheet (new)

- [ ] **Step 1: Write the sheet**

`ios/VMflow/Views/Products/PurchasePricesSheet.swift`:
```swift
import SwiftUI

/// Manage a product's purchase prices: history (★ cheapest, "usual" = newest),
/// add/edit with net/gross toggle + live counterpart, fallback tax %, and margin.
struct PurchasePricesSheet: View {
    let productId: UUID
    let sellprice: Double?

    @StateObject private var vm = PurchasePricesViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var supplierName = ""
    @State private var priceText = ""
    @State private var basis: PriceBasis = .net
    @State private var observedOn = Date()
    @State private var note = ""
    @State private var taxRatePctText = ""
    @State private var editingId: UUID? = nil
    @State private var formError: String?

    private var needRateOverride: Bool { vm.resolvedRate == nil }
    private var effectiveRate: Double? {
        needRateOverride ? Double(taxRatePctText).map { $0 / 100 } : vm.resolvedRate
    }
    private var priceValue: Double? { Double(priceText.replacingOccurrences(of: ",", with: ".")) }
    private var counterpartText: String? {
        guard let p = priceValue, let r = effectiveRate else { return nil }
        let other = PurchaseComparison.counterpart(p, basis: basis, rate: r)
        let label = basis == .net ? String(localized: "gross") : String(localized: "net")
        return String(format: "= %.2f \u{20AC} %@", other, label)
    }
    private var newest: PurchasePrice? { vm.prices.first }
    private var cheapestId: UUID? { vm.prices.min(by: { $0.priceGross < $1.priceGross })?.id }
    private var margin: (rohertrag: Double, spannePct: Double)? {
        guard let n = newest else { return nil }
        return PurchaseComparison.marginNet(sellpriceGross: sellprice, ekNet: n.priceNet, rate: n.taxRate)
    }

    private static let isoDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Recorded prices")) {
                    if vm.prices.isEmpty {
                        Text(String(localized: "No purchase prices recorded yet."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(vm.prices) { p in
                        HStack {
                            if p.id == cheapestId { Text("★") }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.supplierName).font(.subheadline)
                                Text(String(format: "%.2f \u{20AC} %@ · %.2f \u{20AC} %@ · %@",
                                            p.priceNet, String(localized: "net"),
                                            p.priceGross, String(localized: "gross"), p.observedOn))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if p.id == newest?.id {
                                Text(String(localized: "usual")).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { startEdit(p) }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await vm.deletePrice(id: p.id, productId: productId) }
                            } label: { Text(String(localized: "Delete")) }
                        }
                    }
                }

                Section(editingId == nil ? String(localized: "Add purchase price") : String(localized: "Edit purchase price")) {
                    TextField(String(localized: "Supplier"), text: $supplierName)
                    if !vm.suppliers.isEmpty {
                        Menu(String(localized: "Pick existing supplier")) {
                            ForEach(vm.suppliers) { s in Button(s.name) { supplierName = s.name } }
                        }.font(.caption)
                    }
                    TextField(String(localized: "Price per unit"), text: $priceText)
                        .keyboardType(.decimalPad)
                    Picker(String(localized: "Basis"), selection: $basis) {
                        Text(String(localized: "net")).tag(PriceBasis.net)
                        Text(String(localized: "gross")).tag(PriceBasis.gross)
                    }.pickerStyle(.segmented)
                    if let c = counterpartText { Text(c).font(.caption).foregroundStyle(.secondary) }
                    if needRateOverride {
                        TextField(String(localized: "Tax rate % (no rate on product)"), text: $taxRatePctText)
                            .keyboardType(.decimalPad)
                    }
                    DatePicker(String(localized: "Date"), selection: $observedOn, displayedComponents: .date)
                    TextField(String(localized: "Note"), text: $note)
                    if let e = formError { Text(e).font(.caption).foregroundStyle(.red) }
                    Button(editingId == nil ? String(localized: "Add") : String(localized: "Save")) {
                        Task { await submit() }
                    }
                    if editingId != nil {
                        Button(String(localized: "Cancel"), role: .cancel) { resetForm() }
                    }
                }

                if let m = margin {
                    Section(String(localized: "Margin")) {
                        Text(String(format: "%.2f \u{20AC} · %.0f%%", m.rohertrag, m.spannePct))
                        Text(String(localized: "net sell price − usual net purchase price"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(String(localized: "Purchase prices"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .task {
                await vm.loadSuppliers()
                await vm.loadPrices(productId: productId)
                await vm.resolveTaxRate(productId: productId)
            }
        }
    }

    private func startEdit(_ p: PurchasePrice) {
        editingId = p.id
        supplierName = p.supplierName
        basis = PriceBasis(rawValue: p.priceBasis) ?? .net
        priceText = String(format: "%.4f", p.priceBasis == "net" ? p.priceNet : p.priceGross)
        observedOn = Self.isoDate.date(from: p.observedOn) ?? Date()
        note = p.note ?? ""
        taxRatePctText = needRateOverride ? String(format: "%.2f", p.taxRate * 100) : ""
    }

    private func resetForm() {
        editingId = nil; supplierName = ""; priceText = ""; basis = .net
        observedOn = Date(); note = ""; taxRatePctText = ""; formError = nil
    }

    private func submit() async {
        guard !supplierName.trimmingCharacters(in: .whitespaces).isEmpty, let price = priceValue else {
            formError = String(localized: "Supplier and price are required."); return
        }
        if needRateOverride && Double(taxRatePctText) == nil {
            formError = String(localized: "Please provide a tax rate."); return
        }
        formError = nil
        let dateStr = Self.isoDate.string(from: observedOn)
        let override = needRateOverride ? Double(taxRatePctText).map { $0 / 100 } : nil
        let name = supplierName.trimmingCharacters(in: .whitespaces)
        let ok: Bool
        if let id = editingId {
            ok = await vm.updatePrice(id: id, productId: productId, supplierName: name, price: price,
                                      basis: basis.rawValue, observedOn: dateStr, note: note.isEmpty ? nil : note,
                                      taxRateOverride: override)
        } else {
            ok = await vm.addPrice(productId: productId, supplierName: name, price: price,
                                   basis: basis.rawValue, observedOn: dateStr, note: note.isEmpty ? nil : note,
                                   taxRateOverride: override)
        }
        if ok { resetForm() } else { formError = vm.error }
    }
}
```

- [ ] **Step 2: Add to the VMflow target + commit**

```bash
git add ios/VMflow/Views/Products/PurchasePricesSheet.swift ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): PurchasePricesSheet (history, add/edit, net/gross, margin)"
```

### Task 7.2: EK section in ProductDetailSheet

`ProductDetailSheet` has `let productId: UUID` (line 9), a sections `VStack` in `body` (lines 26–41), an existing load `.task` (lines 63–69), and `viewModel.product?.sellprice` available.

- [ ] **Step 1: Add state + summary loading**

In the `ProductDetailSheet` struct, add:
```swift
    @StateObject private var purchaseVM = PurchasePricesViewModel()
    @State private var ekSummary: ProductPurchaseSummary?
    @State private var showPurchasePrices = false
```
Add a loader:
```swift
    private func loadEkSummary() async {
        ekSummary = await purchaseVM.fetchSummaries(productIds: [productId])[productId]
    }
```

- [ ] **Step 2: Add the `ekSection` view** (near the other section computed properties):

```swift
    private var ekSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Purchasing")).font(.headline)
            if let s = ekSummary, s.ekCount > 0, let g = s.newestGross {
                HStack {
                    Text(String(localized: "usual cost")); Spacer()
                    Text(String(format: "%.2f \u{20AC}", g)).foregroundStyle(.secondary)
                }
                if let m = PurchaseComparison.marginNet(sellpriceGross: viewModel.product?.sellprice,
                                                        ekNet: s.newestNet, rate: s.effectiveTaxRate) {
                    HStack {
                        Text(String(localized: "Margin")); Spacer()
                        Text(String(format: "%.0f%%", m.spannePct)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(String(localized: "No purchase prices recorded yet."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button(String(localized: "Manage purchase prices")) { showPurchasePrices = true }
                .font(.subheadline)
        }
    }
```

- [ ] **Step 3: Render it + wire the sheet** — add `ekSection` to the body `VStack` (e.g. right after `machineSection`). In the existing `.task` (line ~64) add `await loadEkSummary()`. Attach the sheet to the same `ScrollView`/root (alongside the existing edit `.sheet`):

```swift
            .sheet(isPresented: $showPurchasePrices, onDismiss: { Task { await loadEkSummary() } }) {
                PurchasePricesSheet(productId: productId, sellprice: viewModel.product?.sellprice)
            }
```

- [ ] **Step 4: Build (⌘B), then commit**

```bash
git add ios/VMflow/Views/Products/ProductDetailSheet.swift
git commit -m "feat(ios): EK summary + manage button in ProductDetailSheet"
```

### Task 7.3: Verdict pill on DealCard

- [ ] **Step 1: Add a pill param + render it**

In `ios/VMflow/Views/Deals/DealCard.swift`, add to the struct (after `var isNew: Bool = false`):
```swift
    struct Pill { let text: String; let color: Color }
    var pill: Pill? = nil
```
In the price `HStack` (the one with `formattedDealPrice`/`formattedDiscount`, lines ~44–66), after the discount view, add:
```swift
                    if let pill {
                        Text(pill.text)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(pill.color)
                    }
```

- [ ] **Step 2: Commit**

```bash
git add ios/VMflow/Views/Deals/DealCard.swift
git commit -m "feat(ios): EK verdict pill slot on DealCard"
```

### Task 7.4: Wire the pill + suppressed section in DealsView

`dealsList` is a `List` with `ForEach(viewModel.groupedDeals) { group in Section { ForEach(group.deals) { deal in DealCard(deal: deal, isNew: viewModel.isNew(deal)) … } } }` (lines ~114–127).

- [ ] **Step 1: Add a pill helper** (in `DealsView`):
```swift
    private func ekPill(for deal: DedupedDeal) -> DealCard.Pill? {
        let ek = viewModel.dealEk(deal)
        guard let v = ek.bestVerdict else { return nil }
        let pct = ek.bestDeltaPct.map { abs(Int($0.rounded())) }
        switch v {
        case .goodBest, .good:
            let suffix = String(localized: "below your cost")
            return .init(text: pct.map { "\($0)% \(suffix)" } ?? suffix, color: .green)
        case .similar:
            return .init(text: String(localized: "≈ your cost"), color: .orange)
        case .worse:
            let suffix = String(localized: "above your cost")
            return .init(text: pct.map { "\($0)% \(suffix)" } ?? suffix, color: .red)
        default:
            return nil
        }
    }
```

> Note: the number and `%` stay **outside** `String(localized:)` (we localize only the suffix). Interpolating an `Int` into a localized string extracts a `%lld…` String-Catalog key that's fragile to match by hand — keeping the number outside avoids that entirely. Same reasoning for the suppressed-section header below.

- [ ] **Step 2: Pass it to DealCard** — change line ~117 to:
```swift
                        DealCard(deal: deal, isNew: viewModel.isNew(deal), pill: ekPill(for: deal))
```

- [ ] **Step 3: Add the suppressed section** — after the `ForEach(viewModel.groupedDeals)` block (still inside the `List`, only in active mode):
```swift
                if viewModel.listMode == .active && !viewModel.suppressedActiveDeals.isEmpty {
                    Section {
                        ForEach(viewModel.suppressedActiveDeals) { deal in
                            DealCard(deal: deal, isNew: false,
                                     pill: .init(text: String(localized: "likely mismatch"), color: .red))
                            // Mirror the same tap-to-open-detail treatment used by group rows above.
                        }
                    } header: {
                        Text("\(viewModel.suppressedActiveDeals.count) " + String(localized: "hidden — above your highest cost"))
                    }
                }
```
> Replicate whatever navigation the group rows use to open the detail sheet (e.g. the same `NavigationLink`/tap that wraps `DealCard` above) so suppressed rows are still inspectable.

- [ ] **Step 4: Build (⌘B), then commit**

```bash
git add ios/VMflow/Views/Deals/DealsView.swift
git commit -m "feat(ios): EK pill wiring + suppressed-deals section in DealsView"
```

### Task 7.5: Comparison line in DealDetailSheet

`productsSection` renders `ForEach(deal.matchedProducts) { p in Button { … } label: { HStack { ProductImage; VStack(alignment: .leading) { name; sellprice; stockBadges } … } } }` (lines ~425–460). `DealDetailSheet` has `viewModel` (a `DealsViewModel`) and `deal` (the live `DedupedDeal`); `deal.primary.dealPrice` is the gross deal price.

- [ ] **Step 1: Add the comparison line** inside that inner `VStack(alignment: .leading)`, right after `stockBadges(for: p.id, compact: false)`:

```swift
                                if let ekLine = ekComparisonLine(for: p) {
                                    Text(ekLine).font(.caption2).foregroundStyle(.secondary)
                                }
```

- [ ] **Step 2: Add the helper** (in `DealDetailSheet`):
```swift
    private func ekComparisonLine(for p: DedupedDeal.MatchedProduct) -> String? {
        guard let summary = viewModel.ekSummaries[p.id], summary.ekCount > 0,
              let usual = summary.newestGross else { return nil }
        let dealGross = deal.primary.dealPrice ?? 0
        var line = String(format: String(localized: "Offer %.2f \u{20AC} vs usual cost %.2f \u{20AC}"), dealGross, usual)
        if let md = PurchaseComparison.marginDelta(sellpriceGross: p.sellprice, dealGross: dealGross, summary: summary) {
            line += " · " + String(format: String(localized: "Margin %.0f%% → %.0f%%"), md.currentPct, md.dealPct)
        }
        return line
    }
```
**Intentional v1 scope cut:** unlike the PWA (Chunk 5 Step 5), the iOS deal detail does **not** add an explicit "+ EK erfassen" button for no-EK products — tapping the matched-product row already navigates to `ProductDetailSheet`, which carries the "Einkauf" section + "Einkaufspreise verwalten" (Task 7.2). This is a deliberate divergence from spec §9.4 to avoid threading a second sheet through the detail view; the capability is one tap away. (If full parity is later wanted, present `PurchasePricesSheet(productId:sellprice:)` from a button here.)

- [ ] **Step 3: Build (⌘B), then commit**

```bash
git add ios/VMflow/Views/Deals/DealDetailSheet.swift
git commit -m "feat(ios): EK comparison line in deal detail matched products"
```

### Task 7.6: German translations + final build

All new UI strings use `String(localized:)` with the English text as the key. Building extracts them into `Localizable.xcstrings`.

- [ ] **Step 1: Extract + translate**

Build the app once (⌘B) so Xcode adds the new keys to `Resources/Localizable.xcstrings`. Then, in Xcode's String Catalog editor, set the **German** translation for each new key:

| Key (English) | German |
|---|---|
| Purchasing | Einkauf |
| Purchase prices | Einkaufspreise |
| Recorded prices | Erfasste Preise |
| No purchase prices recorded yet. | Noch keine Einkaufspreise erfasst. |
| Add purchase price | Einkaufspreis erfassen |
| Edit purchase price | Einkaufspreis bearbeiten |
| Supplier | Lieferant |
| Pick existing supplier | Vorhandenen Lieferanten wählen |
| Price per unit | Preis je Stück |
| Basis | Basis |
| net | netto |
| gross | brutto |
| Tax rate % (no rate on product) | Steuersatz % (kein Satz am Produkt) |
| Date | Datum |
| Note | Notiz |
| usual | üblich |
| Margin | Marge |
| net sell price − usual net purchase price | VK netto − üblicher EK netto |
| Manage purchase prices | Einkaufspreise verwalten |
| usual cost | üblicher EK |
| Supplier and price are required. | Lieferant und Preis sind erforderlich. |
| Please provide a tax rate. | Bitte einen Steuersatz angeben. |
| below your cost | günstiger als dein EK |
| ≈ your cost | ≈ wie dein EK |
| above your cost | teurer als dein EK |
| likely mismatch | evtl. Fehl-Match |
| hidden — above your highest cost | ausgeblendet — über deinem höchsten EK |
| Offer %.2f € vs usual cost %.2f € | Angebot %.2f € vs. üblicher EK %.2f € |
| Margin %.0f%% → %.0f%% | Spanne %.0f%% → %.0f%% |

(Existing keys like "Delete"/"Add"/"Save"/"Cancel"/"Done" are already in the catalog — reuse them.)

- [ ] **Step 2: Full build + simulator smoke test**

Build (⌘B) and run on a Simulator. Verify: Product detail → "Einkauf" section shows üblicher EK + Marge after adding a price via "Einkaufspreise verwalten" (net entry → gross computed; ★ on cheapest; "üblich" on newest). Deals list → green/orange/red pill on cards with EK; a deal priced above the product's highest EK is hidden and appears under the "N ausgeblendet" section; deal detail shows the "Angebot … vs üblicher EK …" line.

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/Resources/Localizable.xcstrings
git commit -m "i18n(ios): German translations for purchase-price + deal EK strings"
```

---

## Done

All seven chunks complete the feature end-to-end: shared backend (tables, RPCs, suppression helper, deal-search push), PWA (composable, product UI, deals comparison), and native iOS parity. The shared comparison logic is unit-tested in TypeScript (Chunk 3) and ported verbatim to Swift (Chunk 6); the suppression rule is centralized server-side (Chunk 2) and consumed identically by both clients. Backward-compatible throughout: with no EK data, every new code path is a no-op and existing behavior is unchanged.

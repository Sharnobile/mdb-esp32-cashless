# Nayax Import Without Stock Change — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in (checkbox, default OFF) to the Nayax reconciliation "Import as manual sales" that inserts the sales **without** decrementing tray stock, while still stamping `product_id`/tax.

**Architecture:** The stock decrement lives in the `stamp_machine_and_decrement_stock` BEFORE-INSERT trigger (step 2). A new migration wraps that step in a guard reading a transaction-local GUC (`vmflow.skip_stock_decrement`), and `insert_manual_sale` gains a `p_adjust_stock boolean DEFAULT true` param that sets the GUC when false. The frontend threads an `adjustStock` flag (default false) from a confirm-dialog checkbox through `bulkImportMissing` into the RPC.

**Tech Stack:** Supabase Postgres (plpgsql, SECURITY DEFINER, GUC via `set_config`/`current_setting`); Nuxt 4 + Vue 3 `<script setup>` + TS; `@nuxtjs/i18n` (en/de); Vitest.

**Spec:** `docs/superpowers/specs/2026-06-02-nayax-import-skip-stock-design.md`

**Skills:** @superpowers:verification-before-completion before claiming done.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `Docker/supabase/migrations/20260602120000_manual_sale_skip_stock.sql` | DB | NEW migration: trigger step-2 guard + `insert_manual_sale` gains `p_adjust_stock` |
| `management-frontend/app/composables/useNayaxReconciliation.ts` | import logic | `bulkImportMissing(rows, adjustStock=false)` → RPC arg + audit metadata |
| `management-frontend/app/components/nayax/NayaxDifferencesTable.vue` | import-confirm UI | `adjustStock` ref + checkbox + reworded body + reset-on-open + pass to import |
| `management-frontend/i18n/locales/en.json`, `…/de.json` | strings | reword `importConfirmBody`; add `adjustStockLabel`, `adjustStockHint` |

All frontend commands run from `management-frontend/`. DB/CLI commands run from repo root.

---

## Chunk 1: Import-without-stock option

### Task 1: DB migration — trigger guard + `insert_manual_sale` param

**Files:**
- Create: `Docker/supabase/migrations/20260602120000_manual_sale_skip_stock.sql`

This is a NEW migration (immutability rule — never edit existing migrations). It re-creates the **current** definitions of the trigger and `insert_manual_sale` from `20260412000000_sales_product_id_snapshot.sql` with the two minimal changes. Copy the existing bodies verbatim except where noted.

- [ ] **Step 1: Create the migration file** with exactly this content:

```sql
-- =========================================================
-- Manual sale: optional stock-skip
--
-- Adds an opt-out of the BEFORE-INSERT stock decrement so historical
-- sales (e.g. Nayax reconciliation imports, where stock was already
-- accounted for at refill) can be recorded WITHOUT changing current_stock.
--
-- Mechanism: insert_manual_sale(p_adjust_stock => false) sets a
-- transaction-local GUC; stamp_machine_and_decrement_stock() skips ONLY
-- its stock-decrement step when that GUC is 'on'. machine_id resolution,
-- tax snapshot, and product_id stamping are unaffected.
--
-- Backward-compatible: GUC unset => decrement (today's behaviour) for every
-- normal insert (MQTT firmware sales never set it); p_adjust_stock DEFAULT
-- true => all existing callers unchanged. Idempotent (CREATE OR REPLACE /
-- DROP IF EXISTS) so safe to re-run via update.sh.
-- =========================================================

-- 1. Trigger: guard ONLY the stock-decrement step --------------------------
CREATE OR REPLACE FUNCTION public.stamp_machine_and_decrement_stock()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_machine_id    uuid;
  v_rows_updated  integer;
  v_product_id    uuid;
  v_country       char(2);
  v_company_id    uuid;
  v_tax_class_id  uuid;
  v_tax_rate      numeric(6,4);
  v_tax_rate_num  numeric;
  v_price_num     numeric;
  v_price_net     numeric(10,4);
BEGIN
  -- 1. Resolve machine_id
  IF NEW.machine_id IS NOT NULL THEN
    v_machine_id := NEW.machine_id;
  ELSE
    SELECT vm.id INTO v_machine_id
    FROM public."vendingMachine" vm
    WHERE vm.embedded = NEW.embedded_id
    LIMIT 1;

    NEW.machine_id := v_machine_id;
  END IF;

  -- 2. Decrement tray stock — skippable via transaction-local GUC set by
  --    insert_manual_sale(p_adjust_stock => false).
  IF coalesce(current_setting('vmflow.skip_stock_decrement', true), 'off') <> 'on' THEN
    IF v_machine_id IS NOT NULL THEN
      UPDATE public.machine_trays
      SET current_stock = greatest(0, current_stock - 1)
      WHERE machine_id = v_machine_id
        AND item_number = NEW.item_number;

      GET DIAGNOSTICS v_rows_updated = ROW_COUNT;

      IF v_rows_updated = 0 THEN
        INSERT INTO public.stock_decrement_log
          (embedded_id, machine_id, item_number, item_price, reason, sale_created_at)
        VALUES
          (NEW.embedded_id, v_machine_id, NEW.item_number, NEW.item_price,
           'no_matching_tray', NEW.created_at);
      END IF;
    ELSE
      INSERT INTO public.stock_decrement_log
        (embedded_id, machine_id, item_number, item_price, reason, sale_created_at)
      VALUES
        (NEW.embedded_id, NULL, NEW.item_number, NEW.item_price,
         'no_machine_for_device', NEW.created_at);
    END IF;
  END IF;

  -- 3. Stamp tax data + product_id (only if machine was resolved)
  IF v_machine_id IS NOT NULL AND NEW.item_price IS NOT NULL THEN
    SELECT
      vm.company,
      COALESCE(vm.country_code, c.country_code, 'DE')
    INTO v_company_id, v_country
    FROM public."vendingMachine" vm
    JOIN public.companies c ON c.id = vm.company
    WHERE vm.id = v_machine_id;

    IF v_company_id IS NOT NULL THEN
      SELECT mt.product_id, COALESCE(p.tax_class_id, pc.tax_class_id)
      INTO v_product_id, v_tax_class_id
      FROM public.machine_trays mt
      JOIN public.products p ON p.id = mt.product_id
      LEFT JOIN public.product_category pc ON pc.id = p.category
      WHERE mt.machine_id = v_machine_id
        AND mt.item_number = NEW.item_number
      LIMIT 1;
    END IF;

    IF v_tax_class_id IS NOT NULL AND v_company_id IS NOT NULL THEN
      SELECT tr.rate INTO v_tax_rate
      FROM public.tax_rates tr
      WHERE tr.company_id = v_company_id
        AND tr.tax_class_id = v_tax_class_id
        AND tr.country_code = v_country
        AND tr.valid_from <= COALESCE(NEW.created_at, now())::date
        AND (tr.valid_to IS NULL OR tr.valid_to >= COALESCE(NEW.created_at, now())::date)
      ORDER BY tr.valid_from DESC
      LIMIT 1;
    END IF;

    IF v_tax_rate IS NOT NULL THEN
      v_tax_rate_num := v_tax_rate::numeric;
      v_price_num    := NEW.item_price::numeric;

      v_price_net := ROUND(v_price_num / (1::numeric + v_tax_rate_num), 4);
      NEW.tax_rate_snapshot := v_tax_rate;
      NEW.price_net := v_price_net;
      NEW.tax_amount := ROUND(v_price_num - v_price_net::numeric, 4);
    END IF;

  ELSIF v_machine_id IS NOT NULL THEN
    SELECT mt.product_id INTO v_product_id
    FROM public.machine_trays mt
    WHERE mt.machine_id = v_machine_id
      AND mt.item_number = NEW.item_number
    LIMIT 1;
  END IF;

  -- 4. Stamp product_id (immutable snapshot of what was sold)
  NEW.product_id := v_product_id;

  RETURN NEW;
END
$$;

-- 2. insert_manual_sale gains p_adjust_stock (DROP+CREATE: the new defaulted
--    param would otherwise create an ambiguous overload with the old 5-arg fn)
DROP FUNCTION IF EXISTS public.insert_manual_sale(uuid, integer, float8, text, timestamptz);

CREATE OR REPLACE FUNCTION public.insert_manual_sale(
  p_machine_id uuid,
  p_item_number integer,
  p_item_price float8,
  p_channel text,
  p_created_at timestamptz DEFAULT now(),
  p_adjust_stock boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_company_id uuid;
  v_new_sale RECORD;
BEGIN
  IF NOT public.i_am_admin() THEN
    RAISE EXCEPTION 'only admins can insert manual sales';
  END IF;

  SELECT vm.company INTO v_company_id
  FROM public."vendingMachine" vm
  WHERE vm.id = p_machine_id;

  IF v_company_id IS NULL OR v_company_id != public.my_company_id() THEN
    RAISE EXCEPTION 'machine does not belong to your company';
  END IF;

  -- Opt out of the trigger's stock decrement for THIS insert (transaction-local).
  IF NOT p_adjust_stock THEN
    PERFORM set_config('vmflow.skip_stock_decrement', 'on', true);
  END IF;

  INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
  VALUES (p_machine_id, p_item_number, p_item_price, p_channel, p_created_at)
  RETURNING id, created_at, machine_id, item_number, item_price, channel, product_id
  INTO v_new_sale;

  RETURN jsonb_build_object(
    'id', v_new_sale.id,
    'created_at', v_new_sale.created_at,
    'machine_id', v_new_sale.machine_id,
    'item_number', v_new_sale.item_number,
    'item_price', v_new_sale.item_price,
    'channel', v_new_sale.channel,
    'product_id', v_new_sale.product_id
  );
END;
$$;
```

- [ ] **Step 2: Apply to the local dev DB**

Run: `supabase --workdir Docker migration up`
Expected: applies `20260602120000_manual_sale_skip_stock.sql` with no error. (Per memory: use `--workdir Docker`, NOT `cd Docker`. NEVER `supabase db reset`.)

- [ ] **Step 3: Verify the trigger guard via a rolled-back transaction** (does NOT mutate dev data)

Run (via the running CLI dev DB container):
```bash
docker exec -i supabase_db_mdb-esp32-cashless psql -U postgres -d postgres <<'SQL'
\set ON_ERROR_STOP on
BEGIN;
-- pick a real machine+tray that has stock AND an assigned product
-- (so product_id stamping is observable)
SELECT machine_id AS mid, item_number AS itm, current_stock AS base
FROM public.machine_trays WHERE current_stock > 0 AND product_id IS NOT NULL LIMIT 1 \gset
\echo baseline stock: :base
-- (a) normal insert -> trigger decrements
INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
VALUES (:'mid', :itm, 1.50, 'cash', now());
SELECT current_stock AS after_decrement, product_id IS NOT NULL AS pid_stamped
FROM public.machine_trays mt
  CROSS JOIN LATERAL (SELECT product_id FROM public.sales WHERE machine_id=:'mid' AND item_number=:itm ORDER BY created_at DESC LIMIT 1) s
WHERE mt.machine_id=:'mid' AND mt.item_number=:itm;
-- expect after_decrement = base-1, pid_stamped = t
-- (b) skip insert -> trigger does NOT decrement, still stamps product_id
SET LOCAL vmflow.skip_stock_decrement = 'on';
INSERT INTO public.sales (machine_id, item_number, item_price, channel, created_at)
VALUES (:'mid', :itm, 1.50, 'cash', now());
SELECT current_stock AS after_skip FROM public.machine_trays WHERE machine_id=:'mid' AND item_number=:itm;
-- expect after_skip = base-1 (UNCHANGED from step a)
SELECT product_id IS NOT NULL AS pid_still_stamped, count(*) AS spurious_log
FROM public.sales s
  LEFT JOIN public.stock_decrement_log l ON l.machine_id=:'mid' AND l.item_number=:itm AND l.sale_created_at > now() - interval '1 minute'
WHERE s.machine_id=:'mid' AND s.item_number=:itm
GROUP BY s.product_id;
ROLLBACK;
SQL
```
Expected: `after_decrement = base - 1`, `pid_stamped = t`; `after_skip = base - 1` (i.e. the skip insert did NOT decrement further); product_id still stamped on the skip insert. Transaction is rolled back so dev data is untouched.

- [ ] **Step 4: Commit** (new migration files are allowed by the pre-commit hook; only edits to existing-on-main migrations are rejected)

```bash
git add Docker/supabase/migrations/20260602120000_manual_sale_skip_stock.sql
git commit -m "feat(db): insert_manual_sale p_adjust_stock + trigger stock-skip guard"
```

### Task 2: i18n strings

**Files:**
- Modify: `management-frontend/i18n/locales/en.json`, `management-frontend/i18n/locales/de.json`

- [ ] **Step 1: Reword `importConfirmBody`** under `nayax.reconcile.results` to drop the stock-decrement clause (stock is now governed by the checkbox):
  - en: `"importConfirmBody": "{n} Nayax rows will be created as manual sales. Continue?"`
  - de: `"importConfirmBody": "{n} Nayax-Zeilen werden als manuelle Verkäufe angelegt. Fortfahren?"`

- [ ] **Step 2: Add two keys** under `nayax.reconcile.results` (both locales; German informal *du*):
  - en:
    ```json
    "adjustStockLabel": "Also reduce tray stock",
    "adjustStockHint": "Off by default — reconciled sales are usually historical and the stock was already counted at refill.",
    ```
  - de:
    ```json
    "adjustStockLabel": "Tray-Bestand ebenfalls reduzieren",
    "adjustStockHint": "Standardmäßig aus — abgeglichene Verkäufe sind meist historisch, der Bestand wurde beim Füllen schon gezählt.",
    ```

- [ ] **Step 3: Validate JSON**

Run: `node -e "JSON.parse(require('fs').readFileSync('i18n/locales/en.json','utf8'));JSON.parse(require('fs').readFileSync('i18n/locales/de.json','utf8'));console.log('ok')"`
Expected: `ok`

- [ ] **Step 4: Commit**

```bash
git add i18n/locales/en.json i18n/locales/de.json
git commit -m "i18n(nayax): stock-neutral import body + adjust-stock checkbox strings"
```

### Task 3: Composable — thread `adjustStock` through `bulkImportMissing`

**Files:**
- Modify: `management-frontend/app/composables/useNayaxReconciliation.ts` (locate the `bulkImportMissing` function by name — do not trust a line number)

- [ ] **Step 1: Change the signature** from `async function bulkImportMissing(rows: NayaxRow[]): Promise<…>` to:
  ```ts
  async function bulkImportMissing(
    rows: NayaxRow[],
    adjustStock = false,
  ): Promise<{ imported: number; errors: string[] }> {
  ```

- [ ] **Step 2: Pass the param to the RPC.** In the `(supabase as any).rpc('insert_manual_sale', { … })` call, add `p_adjust_stock: adjustStock,` after `p_created_at: n.utcDt,`.

- [ ] **Step 3: Record it in the audit log.** In the `logNayaxActivity('sale_inserted', …, { … })` metadata object, add `adjust_stock: adjustStock,`.

- [ ] **Step 4: Confirm nothing broke**

Run: `npx vitest run`
Expected: all green (no `bulkImportMissing` unit test exists; this confirms no type/compile regression in the composable's test scope).

- [ ] **Step 5: Commit**

```bash
git add app/composables/useNayaxReconciliation.ts
git commit -m "feat(nayax): bulkImportMissing threads adjustStock to insert_manual_sale"
```

### Task 4: UI — confirm-dialog checkbox

**Files:**
- Modify: `management-frontend/app/components/nayax/NayaxDifferencesTable.vue`

- [ ] **Step 1: Add the ref.** In `<script setup>`, near `const showConfirm = ref(false)`, add:
  ```ts
  const adjustStock = ref(false)
  ```

- [ ] **Step 2: Reset on open.** Change the bulk-action-bar import button (currently `@click="showConfirm = true"`) to reset the checkbox each time the dialog opens:
  ```vue
  @click="adjustStock = false; showConfirm = true"
  ```

- [ ] **Step 3: Add the checkbox** inside the import-confirm `AppModal`, between the body `<p>` and the button row:
  ```vue
  <label class="mb-4 flex items-start gap-2 text-sm">
    <input v-model="adjustStock" type="checkbox" class="mt-0.5" />
    <span>
      {{ t('nayax.reconcile.results.adjustStockLabel') }}
      <span class="mt-0.5 block text-xs text-muted-foreground">{{ t('nayax.reconcile.results.adjustStockHint') }}</span>
    </span>
  </label>
  ```

- [ ] **Step 4: Pass the flag to the import.** In `runImport()`, change
  `lastResult.value = await recon.bulkImportMissing(rowsToImport)` to
  `lastResult.value = await recon.bulkImportMissing(rowsToImport, adjustStock.value)`.

- [ ] **Step 5: Commit**

```bash
git add app/components/nayax/NayaxDifferencesTable.vue
git commit -m "feat(nayax): import-confirm checkbox to also reduce tray stock (default off)"
```

### Task 5: Final verification

- [ ] **Step 1: Unit tests** — `npx vitest run` → all green.
- [ ] **Step 2: Typecheck** — `npx nuxi typecheck 2>&1 | grep -E "NayaxDifferencesTable|useNayaxReconciliation"` → no NEW errors from these files (the repo has known pre-existing `never`/DB-type errors; only regressions in the touched files block). Confirm the two pre-existing `useNayaxReconciliation.ts` errors (XLSX `WorkSheet|undefined`, `.update→never`) are the only ones there.
- [ ] **Step 3: Preview** (per the preview workflow; backend is the running local Supabase): log in (`test@test.com` / `password123`), open `/reports/nayax-reconciliation`, upload `app/test-helpers/fixtures/nayax-sample.xlsx`, reach the differences table, open the import-confirm dialog, and confirm: the checkbox **"Also reduce tray stock" is present and UNCHECKED by default**, the body no longer claims stock will be decremented, and the hint renders. (Full import requires mapped machines/data; verifying the dialog state is sufficient for the UI change.) `preview_screenshot` the dialog.
- [ ] **Step 4: Commit** any preview fixes:
```bash
git add -A management-frontend/app/components/nayax management-frontend/app/composables
git commit -m "fix(nayax): preview polish for stock-skip import"
```

---

## Done criteria
- Migration applied to dev; rolled-back psql check shows: normal insert decrements + stamps product_id; skip insert does NOT decrement but still stamps product_id; no spurious `stock_decrement_log` on skip.
- `npx vitest run` green; no new typecheck errors in the two touched frontend files.
- Confirm dialog shows the default-OFF "also reduce tray stock" checkbox; body is stock-neutral; both locales render.
- Backward compat intact: `pages/machines/[id].vue` manual add and the firmware MQTT path still decrement (neither sets `p_adjust_stock`/the GUC).
- Unrelated working-tree files (README.md, docs/screenshots/, ios/, MMM-VMflow/, tmp/) untouched; commits scoped.

# Restore a suppressed (auto-removed) sale — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin promote an auto-removed brownout-duplicate (`suppressed_sales` row) back into a real `sales` row — decrementing stock, preserving the product snapshot, removing it from the "auto-removed duplicates" surface and showing it in the normal Sales listing — from both the PWA and the native iOS app.

**Architecture:** One atomic SECURITY DEFINER RPC `restore_suppressed_sale(uuid)` does insert-real-sale (trigger resolves machine + tax + stock −1) → override `product_id` to the snapshot → delete the suppressed row → write an `activity_log` audit. The PWA adds an admin-only per-row button + confirm modal in the Device Health "Auto-removed duplicates" card; iOS converts the Duplicates tab to a `List` with an admin-only swipe-to-action + confirmation dialog.

**Tech Stack:** Supabase Postgres (plpgsql, RLS), Nuxt 4 PWA (Vue 3 `<script setup>`, vitest), SwiftUI (`ios/VMflow`).

**Spec:** `docs/superpowers/specs/2026-06-07-restore-suppressed-sale-design.md`

---

## CRITICAL working-tree & commit rules (read before any commit)

The working tree has **parallel in-flight work that must never be swept into your commits**:
- Modified (leave untouched): `ios/NotificationService/Info.plist`, `ios/VMflow/Models/CashBook.swift`, `ios/VMflow/Resources/Info.plist`, `ios/VMflow/Resources/Localizable.xcstrings`, `ios/VMflow/ViewModels/RefillWizardViewModel.swift`, `ios/VMflow/Views/CashBook/WithdrawalSheet.swift`, `ios/VMflow/Views/Refill/RefillSummaryView.swift`
- Untracked (leave untouched): `Docker/supabase/functions/mqtt-webhook/deno.lock`, `Docker/supabase/migrations/20260606000000_cash_book_per_machine_theoretical.sql`, `Docker/supabase/tests/get_theoretical_cash_per_machine.test.sql`, `MMM-VMflow/`, `ios/VMflow.xcodeproj/xcshareddata/`

**Rules:**
- **NEVER `git add -A`, `git add .`, or `git add <dir>/`** (a directory glob would catch the cash_book migration/test). **Always `git add <exact file paths>`** listed in each commit step.
- Stay on `main` (the user works directly on main; no worktrees).
- The files THIS plan edits — `MachineDetailView.swift`, `MachineDetailViewModel.swift`, `useSuppressedSales.ts`, `machines/[id].vue`, the two i18n JSONs, the new migration, the new SQL test, the new/updated vitest file — are all clean at HEAD, so scoped commits are safe. Before each iOS commit, still run `git status -s <file>` to confirm it has only your changes.
- **NEVER `supabase db reset`** — it wipes live dev data. Use `supabase --workdir Docker migration up` only. (`migration up` applies all pending migrations, including the user's in-flight cash_book one — that is expected and harmless.)
- Commit trailer on every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```

---

## File Structure

| File | Responsibility |
|------|----------------|
| `Docker/supabase/migrations/20260607000000_restore_suppressed_sale.sql` (new) | The `restore_suppressed_sale(uuid)` RPC + GRANTs |
| `Docker/supabase/tests/restore_suppressed_sale.test.sql` (new) | Rolled-back ASSERT test: happy path + 3 negatives |
| `management-frontend/app/composables/useSuppressedSales.ts` | Add `restore(id)` (rpc + optimistic local removal) |
| `management-frontend/app/composables/__tests__/useSuppressedSales.test.ts` (new) | Unit test for `restore` |
| `management-frontend/app/pages/machines/[id].vue` | Extract `reloadSales()`; restore refs + handler; admin-only row button; confirm modal |
| `management-frontend/i18n/locales/en.json`, `de.json` | Restore button/confirm/result keys under `machineDetail` |
| `ios/VMflow/ViewModels/MachineDetailViewModel.swift` | `restoreSuppressed(_:)` |
| `ios/VMflow/Views/Machines/MachineDetailView.swift` | Duplicates tab → `List(.plain)`; admin-only `.swipeActions` + `.confirmationDialog`; `@EnvironmentObject auth` |

---

## Chunk 1: Backend RPC + SQL test

### Task 1: Create the `restore_suppressed_sale` migration

**Files:**
- Create: `Docker/supabase/migrations/20260607000000_restore_suppressed_sale.sql`

- [ ] **Step 1: Write the migration file**

Create `Docker/supabase/migrations/20260607000000_restore_suppressed_sale.sql` with EXACTLY this content:

```sql
-- =========================================================
-- Restore a suppressed (auto-removed) sale as a real sale
--
-- Inverse of the brownout-suppression feature (20260602130000): an admin
-- promotes a suppressed_sales row back into a real public.sales row when the
-- auto-suppression was wrong (the sale was genuinely distinct).
--
-- The BEFORE-INSERT trigger stamp_machine_and_decrement_stock() resolves
-- machine_id from embedded_id, applies the tax snapshot, decrements tray
-- stock by 1, and stamps product_id from the CURRENT tray. We then override
-- product_id with the immutable suppression-time snapshot so the restored
-- sale shows exactly what the "auto-removed duplicates" list showed, even if
-- the tray's product changed since.
--
-- Atomic (one function body = one transaction): insert + product override +
-- delete suppressed row + audit either all succeed or all roll back.
--
-- Admin-only + company-scoped, mirroring delete_sale_and_restore_stock /
-- insert_manual_sale. SECURITY DEFINER + SET search_path = '' with every
-- identifier schema-qualified. Idempotent (CREATE OR REPLACE + explicit
-- GRANT) so safe to re-run via update.sh. Additive / backward-compatible.
-- =========================================================

CREATE OR REPLACE FUNCTION public.restore_suppressed_sale(p_suppressed_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sup     RECORD;
  v_company uuid;
  v_owner   uuid;
  v_new     RECORD;
BEGIN
  IF NOT public.i_am_admin() THEN
    RAISE EXCEPTION 'only admins can restore suppressed sales';
  END IF;

  SELECT ss.id, ss.embedded_id, ss.item_number, ss.item_price, ss.channel,
         ss.sale_seq, ss.device_created_at, ss.received_at, ss.product_id
  INTO v_sup
  FROM public.suppressed_sales ss
  WHERE ss.id = p_suppressed_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'suppressed sale not found';
  END IF;

  -- Company ownership via the originating device.
  SELECT e.company, e.owner_id INTO v_company, v_owner
  FROM public.embeddeds e
  WHERE e.id = v_sup.embedded_id;

  IF v_company IS NULL OR v_company != public.my_company_id() THEN
    RAISE EXCEPTION 'suppressed sale does not belong to your company';
  END IF;

  -- Insert the real sale. The BEFORE-INSERT trigger resolves machine_id,
  -- applies tax, decrements stock by 1, and stamps product_id from the
  -- current tray. We override product_id with the snapshot just below.
  INSERT INTO public.sales
    (owner_id, embedded_id, item_number, item_price, channel, created_at, sale_seq, time_uncertain)
  VALUES
    (v_owner, v_sup.embedded_id, v_sup.item_number, v_sup.item_price, v_sup.channel,
     coalesce(v_sup.device_created_at, v_sup.received_at), v_sup.sale_seq, true)
  RETURNING id, created_at, machine_id, item_number, item_price, channel, product_id
  INTO v_new;

  -- Preserve the snapshot product (tray may have changed since suppression).
  IF v_sup.product_id IS NOT NULL THEN
    UPDATE public.sales SET product_id = v_sup.product_id WHERE id = v_new.id;
    v_new.product_id := v_sup.product_id;
  END IF;

  -- Remove from the auto-removed list.
  DELETE FROM public.suppressed_sales WHERE id = p_suppressed_id;

  -- Audit (user_id auto-fills via the activity_log column DEFAULT auth.uid()).
  INSERT INTO public.activity_log (company_id, entity_type, entity_id, action, metadata)
  VALUES (
    v_company, 'sale', v_new.id::text, 'sale_restored',
    jsonb_build_object(
      'source', 'suppressed_restore',
      'suppressed_id', p_suppressed_id,
      'item_number', v_sup.item_number,
      'item_price', v_sup.item_price,
      'machine_id', v_new.machine_id
    )
  );

  RETURN jsonb_build_object(
    'id', v_new.id,
    'created_at', v_new.created_at,
    'machine_id', v_new.machine_id,
    'item_number', v_new.item_number,
    'item_price', v_new.item_price,
    'channel', v_new.channel,
    'product_id', v_new.product_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.restore_suppressed_sale(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_suppressed_sale(uuid) TO service_role;
```

- [ ] **Step 2: Sanity-check the SQL** — re-read the file. Confirm: every table/function is `public.`/`auth.`-qualified; no `git add -A` will be used; the timestamp `20260607000000` is greater than the latest existing migration (`20260606000000`). Do NOT edit any existing migration (they are immutable).

### Task 2: Write the SQL test (happy path + negatives)

**Files:**
- Create: `Docker/supabase/tests/restore_suppressed_sale.test.sql`

This test mirrors the harness style of `Docker/supabase/tests/get_theoretical_cash_per_machine.test.sql` (single transaction, `ROLLBACK` at the end, plain `ASSERT` in a `DO` block, fake JWT via `set_config('request.jwt.claims', …, true)`). Negative cases use nested `BEGIN … EXCEPTION WHEN OTHERS` subtransactions so a caught `RAISE` doesn't abort the outer transaction.

- [ ] **Step 1: Write the test file**

Create `Docker/supabase/tests/restore_suppressed_sale.test.sql` with EXACTLY this content:

```sql
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

  -- Audit row written with metadata.source (NOT a source column)
  SELECT count(*) INTO v_count FROM public.activity_log
   WHERE action = 'sale_restored'
     AND entity_id = v_sale.id::text
     AND metadata->>'source' = 'suppressed_restore';
  ASSERT v_count = 1, format('expected 1 sale_restored audit row, got %s', v_count);

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

  RAISE NOTICE 'All restore_suppressed_sale tests passed';
END $$;

ROLLBACK;
```

- [ ] **Step 2: Note** — if a later assertion reveals a column that does not exist on `suppressed_sales`/`sales`/`activity_log`, do NOT guess; re-read the relevant migration (`20260602130000_suppressed_sales.sql`, `20260602140000_suppressed_sales_product_id.sql`, `20260101000000_initial_schema.sql`, `20260303200000_history.sql`) and correct the test, not the migration.

### Task 3: Apply the migration and run the test

- [ ] **Step 1: Ensure local Supabase is running** — `supabase --workdir Docker status` (if not started: `supabase --workdir Docker start`). Use `--workdir Docker`, NOT `cd Docker && supabase …` (the Bun CLI fails to parse the multi-line key in `Docker/supabase/.env` from the cwd path).

- [ ] **Step 2: Apply pending migrations**

Run: `supabase --workdir Docker migration up`
Expected: applies `20260607000000_restore_suppressed_sale.sql` (and any other pending migration, e.g. the in-flight cash_book one — expected, harmless). No errors. **Do NOT run `supabase db reset`.**

- [ ] **Step 3: Run the SQL test suite**

Run: `bash Docker/supabase/tests/run-sql-tests.sh`
Expected: `restore_suppressed_sale.test.sql` prints the NOTICEs ("Happy path passed", "Neg 1/2/3 passed", "All restore_suppressed_sale tests passed") and the script reports `PASS`. (The other two test files also run; the cash_book one is the user's in-flight file — it should also pass or be unchanged. If only your file matters, you can run just it: `psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f Docker/supabase/tests/restore_suppressed_sale.test.sql`.)

- [ ] **Step 4: If the test fails**, fix the migration or the test (whichever is wrong) and re-apply. Because the migration is a `CREATE OR REPLACE`, re-running `supabase --workdir Docker migration up` will NOT re-apply an already-recorded migration — to iterate on the function body during development, re-run just the function DDL via psql, or (only if the migration was never committed/applied anywhere yet) you may edit the file and re-apply with `psql -f`. Prefer iterating via psql so the committed migration file stays the source of truth.

- [ ] **Step 5: Commit** (exact paths only — never `git add -A` / `git add Docker/...` dir globs):

```bash
git add Docker/supabase/migrations/20260607000000_restore_suppressed_sale.sql Docker/supabase/tests/restore_suppressed_sale.test.sql
git commit -m "feat(db): restore_suppressed_sale RPC + SQL test

Atomic admin-only RPC promotes a suppressed_sales row into a real sale:
trigger resolves machine + tax + stock -1, product_id overridden to the
snapshot, suppressed row deleted, activity_log 'sale_restored' written.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Chunk 2: PWA — composable, page UI, i18n

### Task 4: Add `restore(id)` to `useSuppressedSales` (TDD)

**Files:**
- Modify: `management-frontend/app/composables/useSuppressedSales.ts`
- Create: `management-frontend/app/composables/__tests__/useSuppressedSales.test.ts`

> **Node version:** vitest needs Node ≥ 20. If `npx vitest` errors with `ERR_UNKNOWN_BUILTIN_MODULE: node:fs/promises`, your shell is on Node v12 — run this first (inline, same command), then vitest:
> `export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; nvm use default`

- [ ] **Step 1: Write the failing test**

Create `management-frontend/app/composables/__tests__/useSuppressedSales.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { ref as vueRef } from 'vue'

// The composable uses bare ref(...) via Nuxt auto-import.
;(globalThis as any).ref = vueRef

const rpc = vi.fn()

vi.mock('#imports', () => {
  const { ref } = require('vue')
  return {
    ref,
    useSupabaseClient: () => ({ rpc }),
  }
})

import { useSuppressedSales } from '../useSuppressedSales'

beforeEach(() => {
  vi.clearAllMocks()
})

describe('useSuppressedSales.restore', () => {
  it('calls the RPC with { p_suppressed_id } and removes the row on success', async () => {
    rpc.mockResolvedValueOnce({ data: { id: 's1' }, error: null })
    const s = useSuppressedSales()
    // seed two rows
    s.rows.value = [
      { id: 's1' } as any,
      { id: 's2' } as any,
    ]
    await s.restore('s1')
    expect(rpc).toHaveBeenCalledWith('restore_suppressed_sale', { p_suppressed_id: 's1' })
    expect(s.rows.value.map(r => r.id)).toEqual(['s2'])
  })

  it('throws and leaves rows untouched on RPC error', async () => {
    rpc.mockResolvedValueOnce({ data: null, error: { message: 'nope' } })
    const s = useSuppressedSales()
    s.rows.value = [{ id: 's1' } as any]
    await expect(s.restore('s1')).rejects.toBeTruthy()
    expect(s.rows.value.map(r => r.id)).toEqual(['s1'])
  })
})
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `cd management-frontend && npx vitest run app/composables/__tests__/useSuppressedSales.test.ts`
Expected: FAIL — `s.restore is not a function`.

- [ ] **Step 3: Implement `restore`**

In `management-frontend/app/composables/useSuppressedSales.ts`, add a `restore` function inside `useSuppressedSales` (after `fetchMore`, before the `return`) and export it.

```ts
  async function restore(id: string) {
    const { error } = await (supabase as any).rpc('restore_suppressed_sale', { p_suppressed_id: id })
    if (error) throw error
    // Optimistically drop it from the local list (mirrors the delete-sale flow).
    rows.value = rows.value.filter(r => r.id !== id)
  }
```

Update the return statement:

```ts
  return { rows, loading, hasMore, fetchRows, fetchMore, restore }
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `cd management-frontend && npx vitest run app/composables/__tests__/useSuppressedSales.test.ts`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit** (exact paths only):

```bash
git add management-frontend/app/composables/useSuppressedSales.ts management-frontend/app/composables/__tests__/useSuppressedSales.test.ts
git commit -m "feat(pwa): useSuppressedSales.restore() + unit test

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 5: PWA page — reloadSales extraction, restore handler, button, modal, i18n

**Files:**
- Modify: `management-frontend/app/pages/machines/[id].vue`
- Modify: `management-frontend/i18n/locales/en.json`
- Modify: `management-frontend/i18n/locales/de.json`

> No unit test for the page (it has no existing page-level test harness; the composable is the tested unit). Verification is `npm run build` + manual. Keep edits minimal and follow the existing delete-sale pattern exactly.

- [ ] **Step 1: Add i18n keys (en)** — in `management-frontend/i18n/locales/en.json`, `suppressedReason` is currently the **last** key of the `machineDetail` object (line ~399, **no trailing comma**, immediately followed by `}`). Do an exact find-and-replace so JSON stays valid (the existing key gains a comma; the new last key has none).

Find:
```json
    "suppressedReason": "likely brownout re-report"
```
Replace with:
```json
    "suppressedReason": "likely brownout re-report",
    "suppressedRestore": "Take up as sale",
    "suppressedRestoreConfirmTitle": "Take up as real sale?",
    "suppressedRestoreConfirmBody": "This adds a real sale and reduces stock by 1.",
    "suppressedRestoreConfirmAction": "Take up as sale",
    "suppressedRestoring": "Taking up…"
```

- [ ] **Step 2: Add i18n keys (de)** — same exact find-and-replace in `management-frontend/i18n/locales/de.json` (`suppressedReason` is likewise the last `machineDetail` key with no trailing comma).

Find:
```json
    "suppressedReason": "vermutlich Brownout-Doppelmeldung"
```
Replace with:
```json
    "suppressedReason": "vermutlich Brownout-Doppelmeldung",
    "suppressedRestore": "Als Verkauf übernehmen",
    "suppressedRestoreConfirmTitle": "Als echten Verkauf übernehmen?",
    "suppressedRestoreConfirmBody": "Fügt einen echten Verkauf hinzu und reduziert den Bestand um 1.",
    "suppressedRestoreConfirmAction": "Übernehmen",
    "suppressedRestoring": "Wird übernommen…"
```

> After both edits, sanity-check validity: `node -e "JSON.parse(require('fs').readFileSync('management-frontend/i18n/locales/en.json','utf8'));JSON.parse(require('fs').readFileSync('management-frontend/i18n/locales/de.json','utf8'));console.log('json ok')"` → prints `json ok`.

- [ ] **Step 3: Destructure `restore` from the composable** — in `management-frontend/app/pages/machines/[id].vue`, find the line (~42):

```ts
const { rows: suppressedRows, loading: suppressedLoading, hasMore: suppressedHasMore, fetchRows: fetchSuppressed, fetchMore: fetchMoreSuppressed } = useSuppressedSales()
```

and append `, restore: restoreSuppressed` before the closing brace:

```ts
const { rows: suppressedRows, loading: suppressedLoading, hasMore: suppressedHasMore, fetchRows: fetchSuppressed, fetchMore: fetchMoreSuppressed, restore: restoreSuppressed } = useSuppressedSales()
```

- [ ] **Step 4: Extract a reusable `reloadSales()`** — to refresh the Sales list after a restore (DRY: the same 30-day query runs in `onMounted`).

In `onMounted` (~lines 225-238), the sales fetch is currently an inline promise that uses a local `const thirtyDaysAgo` (line ~225). Replace the inline promise inside the `promises` array:

```ts
      supabase
        .from('sales')
        .select('id, created_at, item_price, item_number, channel, product_id, products(name, image_path)')
        .eq('machine_id', id)
        .gte('created_at', thirtyDaysAgo)
        .order('created_at', { ascending: false })
        .then(({ data: salesData, error: salesError }: any) => {
          if (salesError) throw salesError
          sales.value = salesData ?? []
        }),
```

with a call to a new helper:

```ts
      reloadSales(id),
```

Then add the helper near the other top-level functions in `<script setup>` (e.g. just below `onMounted`'s closing, next to `salesChartData`):

```ts
async function reloadSales(machineId: string) {
  const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString()
  const { data, error } = await (supabase as any)
    .from('sales')
    .select('id, created_at, item_price, item_number, channel, product_id, products(name, image_path)')
    .eq('machine_id', machineId)
    .gte('created_at', thirtyDaysAgo)
    .order('created_at', { ascending: false })
  if (error) throw error
  sales.value = data ?? []
}
```

**Then remove the now-orphaned `const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString()` line in `onMounted` (~line 225)** — after the replacement above, `thirtyDaysAgo` has no remaining references in `onMounted` (the helper computes its own), so leaving it would be dead code. Verify with `grep -n thirtyDaysAgo 'management-frontend/app/pages/machines/[id].vue'` (quote the bracket path — zsh globs `[id]`) → should show only the one occurrence inside the new `reloadSales` helper.

- [ ] **Step 5: Add restore confirm state + handler** — near the delete-sale refs (~lines 1051-1053: `showDeleteSaleConfirm`, `deletingSale`, `deletingSaleLoading`), add:

```ts
const showRestoreConfirm = ref(false)
const restoringRow = ref<any>(null)
const restoringLoading = ref(false)
```

Near `confirmDeleteSale` / `handleDeleteSale` (~lines 1083-1134), add:

```ts
function confirmRestoreSuppressed(row: any) {
  restoringRow.value = row
  showRestoreConfirm.value = true
}

async function handleRestoreSuppressed() {
  if (!restoringRow.value?.id || !machine.value) return
  restoringLoading.value = true
  try {
    await restoreSuppressed(restoringRow.value.id)   // rpc + optimistic removal from suppressedRows
    // Audit is written inside the RPC — do NOT call logSaleActivity here (avoids a double entry).
    await reloadSales(machine.value.id)              // restored sale appears in Sales tab
    await fetchTrays(machine.value.id, { silent: true })  // stock -1 reflected
  } catch (err: any) {
    console.error('Failed to restore suppressed sale:', err)
  } finally {
    restoringLoading.value = false
    showRestoreConfirm.value = false
    restoringRow.value = null
  }
}
```

- [ ] **Step 6: Add the admin-only restore button to each suppressed row** — in the suppressed card's row block (~line 2179, `<div v-for="row in suppressedRows" …>`). The row currently ends after the time-ago span. Add a trailing admin-only button. Replace the row's outer element so the button sits at the end of the flex row:

Find:
```html
                  <div v-for="row in suppressedRows" :key="row.id" class="flex items-start gap-3 px-4 py-3">
```
Keep it, and INSIDE it, after the closing `</div>` of the "Main info" block (the `<div class="flex-1 min-w-0"> … </div>`, right before the row's own closing `</div>` at ~line 2209), insert:

```html
                    <button
                      v-if="isAdmin"
                      class="shrink-0 self-center rounded-md border px-2.5 py-1 text-xs font-medium text-foreground hover:bg-muted transition-colors disabled:opacity-50"
                      :title="t('machineDetail.suppressedRestore')"
                      @click="confirmRestoreSuppressed(row)"
                    >
                      {{ t('machineDetail.suppressedRestore') }}
                    </button>
```

(`isAdmin` already exists on the page, line 45. The row is a `flex items-start`, so `self-center` vertically centers the button.)

- [ ] **Step 7: Add the confirm modal** — after the delete-sale `AppModal` (closes at ~line 2248), add a sibling modal:

```html
      <AppModal v-model:open="showRestoreConfirm" :title="t('machineDetail.suppressedRestoreConfirmTitle')" size="sm">
        <p class="text-sm text-muted-foreground">{{ t('machineDetail.suppressedRestoreConfirmBody') }}</p>
        <div v-if="restoringRow" class="mt-3 rounded-md border bg-muted/30 p-3 text-sm">
          <div class="flex items-center justify-between">
            <span class="font-medium">{{ suppressedProduct(restoringRow)?.name ?? `${t('machineDetail.slot')} ${restoringRow.item_number ?? '—'}` }}</span>
            <span class="font-medium">{{ restoringRow.item_price != null ? formatCurrency(restoringRow.item_price, locale) : '—' }}</span>
          </div>
          <p class="mt-1 text-xs text-muted-foreground">{{ formatDateTime(restoringRow.received_at, locale) }}</p>
        </div>
        <div class="mt-4 flex justify-end gap-2">
          <button class="h-9 rounded-md border px-4 text-sm hover:bg-muted" @click="showRestoreConfirm = false">{{ t('common.cancel') }}</button>
          <button
            class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
            :disabled="restoringLoading"
            @click="handleRestoreSuppressed"
          >
            {{ restoringLoading ? t('machineDetail.suppressedRestoring') : t('machineDetail.suppressedRestoreConfirmAction') }}
          </button>
        </div>
      </AppModal>
```

- [ ] **Step 8: Type-check / build** (Node ≥ 20, see note in Task 4)

Run: `cd management-frontend && npx vitest run` (the whole suite — confirms nothing regressed) then `npm run build`
Expected: vitest all-pass; build completes with no type errors. (If `npm run build` is too slow/unavailable in the environment, at minimum run `npx nuxi typecheck` or note it for the user.)

- [ ] **Step 9: Commit** (exact paths only — **single-quote the `[id].vue` path**: the user's shell is zsh, where unquoted `[id]` is a glob and `git add` would abort with `zsh: no matches found`):

```bash
git add 'management-frontend/app/pages/machines/[id].vue' management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "feat(pwa): restore an auto-removed sale from the Device Health card

Admin-only per-row 'Take up as sale' + confirm modal; refreshes the
suppressed list (optimistic), the Sales list, and trays on success.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Chunk 3: iOS — ViewModel method + Duplicates tab swipe-to-action

> **iOS build note:** there is no iOS unit-test harness — verification is a manual Xcode build/run. If Xcode/`xcodebuild` is unavailable to the executor, make the edits, sanity-check them by reading, and report that a manual Xcode build is required.
>
> **Commit handling:** `MachineDetailView.swift` and `MachineDetailViewModel.swift` are clean at HEAD. Before committing, run `git status -s ios/VMflow/Views/Machines/MachineDetailView.swift ios/VMflow/ViewModels/MachineDetailViewModel.swift` to confirm only your changes are present, then `git add` exactly those two paths. **Never `git add -A`** — the tree has unrelated in-flight iOS files (CashBook/Refill).

### Task 6: Add `restoreSuppressed(_:)` to the ViewModel

**Files:**
- Modify: `ios/VMflow/ViewModels/MachineDetailViewModel.swift`

- [ ] **Step 1: Add the method** — in `MachineDetailViewModel` (after `loadSuppressedSales()`, before `// MARK: - Stock Actions`), add:

```swift
    // MARK: - Restore suppressed sale

    /// Promote an auto-removed (suppressed) sale back into a real sale via the
    /// restore_suppressed_sale RPC, then reload so it leaves Duplicates and
    /// appears under Sales (stock −1). Admin-only; the RPC enforces it too.
    func restoreSuppressed(_ id: UUID) async {
        struct Params: Encodable { let p_suppressed_id: UUID }
        do {
            try await client
                .rpc("restore_suppressed_sale", params: Params(p_suppressed_id: id))
                .execute()
            await loadDetail()   // refreshes trays, sales, AND suppressedSales
        } catch is CancellationError {
            // Ignore — SwiftUI cancels routinely
        } catch {
            self.error = error.localizedDescription
        }
    }
```

(`client` is the existing `private let client = SupabaseService.shared.client`. `loadDetail()` already reloads sales + `loadSuppressedSales()`.)

- [ ] **Step 2: Sanity-check** — confirm the method compiles in context (uses existing `client`, `loadDetail`, `error`). No other change in this file.

### Task 7: Convert the Duplicates tab to a `List` with swipe-to-action

**Files:**
- Modify: `ios/VMflow/Views/Machines/MachineDetailView.swift`

This task (a) adds admin access + restore confirm state to the view, and (b) rewrites the `suppressedTab` populated branch from `ScrollView { VStack { … LazyVStack } }` to a `List(.plain)` with custom `Section` headers (reusing `DaySectionHeader`) and an admin-only `.swipeActions` per row. The `SuppressedSaleRow`, `groupSuppressedByDay`, `DaySectionHeader`, and `dayLabel` are all unchanged and reused.

- [ ] **Step 1: Add the admin env-object + restore state** — near the top of the `MachineDetailView` struct, next to the existing `@EnvironmentObject private var realtime: RealtimeService` (line ~16), add:

```swift
    @EnvironmentObject private var auth: AuthService
```

and next to the view's other `@State` properties (e.g. near `selectedProduct`), add:

```swift
    @State private var showRestoreConfirm = false
    @State private var rowToRestore: SuppressedSale?
```

Add a computed admin flag (place it among the view's other private computed/helpers, e.g. just above `groupSuppressedByDay`):

```swift
    private var isAdmin: Bool { auth.role == .admin }
```

> Verify `OrganizationRole` has a `.admin` case (it's used as `auth.role` of type `OrganizationRole?`; `SettingsView` reads `auth.role`). If the case is spelled differently, match the actual enum. `AuthService` is injected at the app root (SettingsView consumes it the same way), so `@EnvironmentObject` is safe here.

- [ ] **Step 2: Rewrite the `suppressedTab` populated branch as a `List`** — replace the ENTIRE current `suppressedTab` computed property (lines ~339-396, from `private var suppressedTab: some View {` through its closing `}` that ends with the `.refreshable { await viewModel.loadDetail() }` block) with:

```swift
    private var suppressedTab: some View {
        Group {
            if viewModel.isLoading {
                ScrollView {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            } else {
                List {
                    // Header card
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "doc.badge.minus")
                                .foregroundStyle(.orange)
                            Text("\(viewModel.suppressedSales.count) auto-removed")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                        }
                        Text("Sales auto-dropped as suspected brownout re-reports.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    if viewModel.suppressedSales.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 40))
                                .foregroundStyle(.green)
                            Text("None — no duplicates auto-removed.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else {
                        let groups = groupSuppressedByDay(viewModel.suppressedSales)
                        ForEach(groups, id: \.date) { group in
                            Section {
                                ForEach(group.rows) { sale in
                                    SuppressedSaleRow(sale: sale, trays: viewModel.trays)
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            if isAdmin {
                                                Button {
                                                    rowToRestore = sale
                                                    showRestoreConfirm = true
                                                } label: {
                                                    Label("Take up as sale", systemImage: "checkmark.circle")
                                                }
                                                .tint(.green)
                                            }
                                        }
                                }
                            } header: {
                                DaySectionHeader(label: dayLabel(for: group.date), count: group.rows.count, unit: "removed")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .refreshable {
            await viewModel.loadDetail()
        }
        .confirmationDialog(
            "Take up as real sale?",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("Take up as sale") {
                if let sale = rowToRestore {
                    Task { await viewModel.restoreSuppressed(sale.id) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Adds a real sale and reduces stock by 1.")
        }
    }
```

Notes for the implementer:
- This is two deliberate deviations from `DealsView` (which uses `.listStyle(.insetGrouped)` + `allowsFullSwipe: true`): we use `.listStyle(.plain)` to keep the flat card look and `allowsFullSwipe: false` so a money/stock action can't fire on an accidental full swipe.
- `SuppressedSale.id` is a `UUID` (`rowToRestore?.id` passes straight to `restoreSuppressed(_:)`).
- Do NOT touch `salesTab`, `SaleRow`, `groupSuppressedByDay`, `SuppressedDayGroup`, `DaySectionHeader`, `dayLabel`, or `SuppressedSaleRow` — they are reused as-is.

- [ ] **Step 3: Build in Xcode** — open `ios/VMflow.xcodeproj`, build (or `xcodebuild -scheme VMflow build` if the CLI is set up). Expected: compiles. Manually verify on a machine with suppressed rows: the Duplicates tab is still day-grouped (sticky "Today/Yesterday/date · N removed" headers) and card-styled; swiping a row left reveals a green "Take up as sale" (only when logged in as admin); tapping it shows the confirmation; confirming removes it from Duplicates and it appears under Sales with stock −1. (If Xcode is unavailable, report that a manual build is required.)

- [ ] **Step 4: Commit** (confirm clean first; exact paths only):

```bash
git status -s ios/VMflow/Views/Machines/MachineDetailView.swift ios/VMflow/ViewModels/MachineDetailViewModel.swift
git add ios/VMflow/Views/Machines/MachineDetailView.swift ios/VMflow/ViewModels/MachineDetailViewModel.swift
git commit -m "feat(ios): restore an auto-removed sale via swipe on the Duplicates tab

Convert the Duplicates tab to List(.plain) (keeps DaySectionHeader
day-grouping) with an admin-only swipe 'Take up as sale' + confirmation
calling restore_suppressed_sale, then reloads detail.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

> If `git status -s` shows the file has unexpected in-flight changes (a parallel session touched it), do NOT commit — make your additive edits, leave them unstaged, and report the diff to the user.

---

## Done criteria
- `restore_suppressed_sale(uuid)` exists, admin- + company-gated, atomic, decrements stock, preserves the snapshot `product_id`, deletes the suppressed row, writes a `sale_restored` audit; SQL test passes (happy + 3 negatives).
- PWA: admin-only "Take up as sale" per suppressed row → confirm → the row leaves the "Auto-removed duplicates" card and the sale appears in the Sales tab with stock −1; `useSuppressedSales.restore` unit-tested; vitest suite green; build clean.
- iOS: Duplicates tab is a `List(.plain)` keeping day-grouping; admin-only swipe-to-action + confirmation restores the sale via the RPC and reloads; builds in Xcode.
- Backward-compatible/additive throughout; migrations immutable (new file only); no unrelated/in-flight files committed.
```

# Nayax reconciliation: import missing sales without changing tray stock

**Date:** 2026-06-02
**Area:** `Docker/supabase` (DB) + `management-frontend` (`/reports/nayax-reconciliation`)
**Type:** Additive feature on an existing tool + a backward-compatible DB migration

## Problem

In the Nayax reconciliation tool, "Import as manual sales" inserts each selected
missing Nayax row via the `insert_manual_sale` RPC, which (through the
`stamp_machine_and_decrement_stock` BEFORE-INSERT trigger) **decrements the
tray's `current_stock`**. For reconciliation, the imported sales are typically
**old** — the physical stock was already accounted for when the machine was
refilled — so decrementing now double-counts and corrupts current stock levels.

## Goal

Add an **option** to import the missing sales **without** changing tray stock,
while still recording the sale completely and correctly (machine_id resolution,
tax snapshot, and `product_id` stamping all still happen). Presented as a
**checkbox in the import-confirm dialog, defaulting to OFF** (the common
reconciliation case); checking it restores today's decrement behaviour.

## Why the change must touch the trigger, not just the RPC

The stock decrement lives in **step 2** of `stamp_machine_and_decrement_stock`
(`Docker/supabase/migrations/20260412000000_sales_product_id_snapshot.sql`,
lines ~66-90): the trigger updates `machine_trays.current_stock = greatest(0,
current_stock - 1)` and writes `stock_decrement_log` rows on no-tray/no-machine.
`insert_manual_sale` itself only does an `INSERT INTO sales`. So skipping the
decrement requires the **trigger** to conditionally skip step 2.

## Approach (chosen): transaction-local GUC + optional `p_adjust_stock` param

Rejected alternatives: (B) a separate `insert_manual_sale_no_stock` RPC — the
trigger guard is needed regardless, so B only duplicates insert logic; (C) a
`sales.skip_stock` column — would also let a later delete skip stock-restore
(see Known limitation) but adds a permanent niche column for a rare case (YAGNI).

### DB — new migration `YYYYMMDDHHMMSS_manual_sale_skip_stock.sql`

Existing migrations stay untouched (immutability rule). All operations
idempotent / safe to re-run via `update.sh` on existing installs.

1. **`CREATE OR REPLACE FUNCTION public.stamp_machine_and_decrement_stock()`** —
   copy the **current body verbatim** from `20260412000000_sales_product_id_snapshot.sql`
   (it is the latest definition), changing only **step 2**: wrap the entire
   "decrement tray stock + stock_decrement_log" block in
   ```sql
   IF coalesce(current_setting('vmflow.skip_stock_decrement', true), 'off') <> 'on' THEN
     -- … existing step-2 body unchanged …
   END IF;
   ```
   Steps 1 (machine_id resolve), 3 (tax), and 4 (`product_id` stamp) are
   **unchanged** and always run. Trigger signature is unchanged, so
   `CREATE OR REPLACE` applies cleanly (no overload issue).
   `current_setting(..., true)` = `missing_ok`, returns NULL when unset → the
   guard defaults to **decrementing** (today's behaviour) for every normal
   insert (MQTT firmware sales never set the GUC).

2. **Replace `insert_manual_sale` with an added `p_adjust_stock` param.**
   Because adding a parameter changes the signature (overload ambiguity with the
   old 5-arg version), DROP then CREATE:
   ```sql
   DROP FUNCTION IF EXISTS public.insert_manual_sale(uuid, integer, float8, text, timestamptz);
   CREATE OR REPLACE FUNCTION public.insert_manual_sale(
     p_machine_id uuid,
     p_item_number integer,
     p_item_price float8,
     p_channel text,
     p_created_at timestamptz DEFAULT now(),
     p_adjust_stock boolean DEFAULT true
   ) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
   …  -- body verbatim from 20260412000000, with this added BEFORE the INSERT:
     IF NOT p_adjust_stock THEN
       PERFORM set_config('vmflow.skip_stock_decrement', 'on', true);  -- txn-local
     END IF;
   …
   $$;
   ```
   `DEFAULT true` ⇒ every existing caller (iOS, the manual-sale add on
   `/machines/[id]`, and the current reconciliation import) keeps decrementing
   with no code change. `set_config(..., true)` is transaction-local; PostgREST
   runs each RPC call in its own transaction and `bulkImportMissing` calls the
   RPC **once per row**, so the flag never leaks between sales.

### Frontend

- **`app/composables/useNayaxReconciliation.ts`** — `bulkImportMissing(rows, adjustStock = false)`:
  pass `p_adjust_stock: adjustStock` in the `insert_manual_sale` RPC call; add
  `adjust_stock: adjustStock` to the `logNayaxActivity('sale_inserted', …)`
  metadata for audit. Default `false` matches the checkbox default.
- **`app/components/nayax/NayaxDifferencesTable.vue`** — in the import-confirm
  `AppModal`, add a checkbox **"Tray-Bestand reduzieren"** bound to a local
  `adjustStock` ref defaulting to `false`; pass it to `runImport()` →
  `bulkImportMissing(rows, adjustStock.value)`. The confirm body text reflects
  the choice (stock unchanged vs. decremented). Reset `adjustStock` to its
  default when the modal reopens.
- **`i18n/locales/{en,de}.json`** — add `nayax.reconcile.results.adjustStockLabel`
  and two confirm-body variants (or a parameterised body). German informal *du*.

## Backward compatibility

- Trigger guard defaults to decrement when the GUC is unset → no behaviour change
  for MQTT firmware sales or any insert that doesn't opt out.
- `insert_manual_sale` `DEFAULT true` → all existing callers unchanged.
- New migration auto-applies via `update.sh`; idempotent on re-run.

## Known limitation (documented, not solved)

A no-stock-imported sale later removed via the ghost-delete
(`delete_sale_and_restore_stock`) would **restore** (+1) stock that was never
decremented. Unlikely in practice: a just-imported "missing" row becomes
*matched* on the next re-run and no longer appears in the phantom/ghost delete
list. Fully solving it needs approach C (a persisted `skip_stock` marker the
delete path also honours) — intentionally out of scope.

## Testing / verification

- **DB (manual, dev DB via `docker exec … psql`):** call `insert_manual_sale`
  with `p_adjust_stock => false` → assert the matching `machine_trays.current_stock`
  is **unchanged** and the sale row still has `product_id` (and tax) stamped;
  call with `true` (or omitted) → assert `current_stock` decremented by 1. Also
  confirm no spurious `stock_decrement_log` row is written on the no-stock path.
- **Frontend:** existing Vitest suite must stay green (no `bulkImportMissing`
  unit test exists; it hits Supabase). Checkbox wiring + confirm-text + the
  default-OFF behaviour verified via the preview workflow.

## Files touched

| File | Change |
|------|--------|
| `Docker/supabase/migrations/<new>_manual_sale_skip_stock.sql` | CREATE OR REPLACE trigger with step-2 guard; DROP+CREATE `insert_manual_sale` with `p_adjust_stock` |
| `management-frontend/app/composables/useNayaxReconciliation.ts` | `bulkImportMissing(rows, adjustStock=false)` + RPC arg + audit metadata |
| `management-frontend/app/components/nayax/NayaxDifferencesTable.vue` | import-confirm checkbox + dynamic body text |
| `management-frontend/i18n/locales/en.json`, `…/de.json` | checkbox label + confirm-body strings |

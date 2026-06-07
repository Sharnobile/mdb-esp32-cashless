# Restore a suppressed (auto-removed) sale as a real sale

**Date:** 2026-06-07
**Area:** Supabase (new migration) + `management-frontend` (PWA) + `ios/VMflow` (native iOS)
**Type:** Additive feature — promote an auto-removed brownout-duplicate back into a real sale

## Goal

Let an admin take an auto-removed sale (a row in `suppressed_sales`, shown in the PWA "Auto-removed duplicates" card and the iOS "Duplicates" tab) and **promote it into a real `sales` row**. After restore the entry must:
- disappear from the "auto-removed duplicates" surface, and
- appear in the normal Sales listing,
- with stock decremented by 1 (the sale really happened), and
- carrying the **same product** the suppressed list showed (immutable snapshot).

This is the inverse of the brownout-suppression feature (2026-06-02): suppression auto-drops a suspected duplicate; restore is the manual "no, that one was real — count it" escape hatch when suppression was wrong.

## Background

The suppression feature (`mqtt-webhook` → `decideSuppress` → `suppressed_sales`) auto-drops a `time_uncertain` sale that looks like a brownout re-report of a recent real sale. It's a heuristic (`±30 s` window, same item/price/channel) and can occasionally drop a genuinely distinct sale (e.g. two real buys of the same item seconds apart). The admin needs a one-action way to reverse a wrong suppression.

`suppressed_sales` columns (from `20260602130000` + `20260602140000`): `id, embedded_id, item_number, item_price, channel, sale_seq, device_created_at, received_at, matched_sale_id, reason, product_id`. The `product_id` is the immutable snapshot stamped at suppression time.

The existing `delete_sale_and_restore_stock` and `insert_manual_sale` RPCs establish the exact pattern to mirror (admin check, company-ownership check, trigger-driven insert, jsonb return, explicit re-GRANT).

## Scope / non-goals

**In scope:** the `restore_suppressed_sale` RPC; PWA per-row restore button + confirm in the Device Health "Auto-removed duplicates" card; iOS swipe-to-action restore on the "Duplicates" tab.

**Out of scope / non-goals:**
- The Nayax reconciliation view (`/reports/nayax-reconciliation`) — untouched. (Its "missing-in-DB" import path is a different flow.)
- Bulk restore — single row at a time only (YAGNI).
- "Undo restore" as a dedicated action — to reverse a restore, delete the resulting sale via the existing delete-sale UI (which restores stock). The suppressed row is **not** recreated.
- No change to the suppression heuristic itself.

## Design

### 1. Backend — new migration `YYYYMMDDHHMMSS_restore_suppressed_sale.sql`

A new, immutable migration adding one SECURITY DEFINER RPC. Mirrors `insert_manual_sale` / `delete_sale_and_restore_stock` exactly (admin gate, company-ownership gate, `SET search_path = ''`, all identifiers schema-qualified, explicit GRANTs).

```sql
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

  -- Insert the real sale. The BEFORE-INSERT trigger
  -- (stamp_machine_and_decrement_stock) resolves machine_id from embedded_id,
  -- applies the tax snapshot, decrements tray stock by 1, and stamps product_id
  -- from the CURRENT tray. We then override product_id with the immutable
  -- snapshot so the restored sale shows exactly what the suppressed list showed.
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

  -- Audit (user_id auto-fills via the column's DEFAULT auth.uid()).
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

**Why these choices:**
- **Insert by `embedded_id`, not `machine_id`** — mirrors the webhook's real-sale insert; the trigger resolves `machine_id`. This is the same path a genuine MQTT sale takes, so the restored row is indistinguishable from one that was never suppressed.
- **`owner_id` set from `embeddeds.owner_id`** — matches the webhook (`owner_id: embedded.owner_id`), so the restored sale looks like a device sale, not a manual one. May be `NULL` on legacy devices; `sales.owner_id` is nullable and the webhook copies it as-is too, so **no NOT-NULL guard**.
- **`created_at = coalesce(device_created_at, received_at)`** — prefer the real device clock; fall back to ingest time when the device timestamp was absent. NOTE this *differs* from the webhook, which recorded `now()` (server time) as a `time_uncertain` sale's `created_at` and used the device timestamp only for the separate `device_created_at` audit column. Preferring the device clock here yields a `created_at` closer to the true vend time — a deliberate (slightly better) choice, not a copy of the webhook's behaviour.
- **`sale_seq` preserved** — the suppressed row's seq was never inserted into `sales`, so re-inserting it is safe and re-arms `UNIQUE(embedded_id, sale_seq)` idempotency against any future re-delivery of that exact seq. (Edge case below.)
- **`time_uncertain = true`** — faithful to provenance: these were uncertain-clock readings by construction. It is a plain data column; nothing auto-processes it on a direct INSERT (suppression only runs in the webhook on MQTT ingest, which this path bypasses).
- **`product_id` override** — the trigger re-derives `product_id` from the *current* tray; we overwrite it with the suppression-time snapshot so the restored sale carries the same product the user saw in the list, even if the tray's product changed since. `coalesce`-style guard: only override when the snapshot is non-null (legacy/null snapshot → keep the trigger's derivation).
- **Atomic** — insert + product override + delete + audit are one function body = one transaction. Any failure rolls back all of it; nothing is half-done.

### 2. PWA — Device Health "Auto-removed duplicates" card (`app/pages/machines/[id].vue`)

- **Composable** (`app/composables/useSuppressedSales.ts`): add `async function restore(id: string)` calling `supabase.rpc('restore_suppressed_sale', { p_suppressed_id: id })`; throw on error. Export it. (No optimistic local mutation in the composable — the page re-fetches both lists, see below.)
- **Card** (per-row block at ~line 2179): add an **admin-only** (`v-if="isAdmin"`) restore control on each row — a small button/icon ("Take up as sale"). `isAdmin` already exists on the page (`role.value === 'admin'`).
- **Confirmation:** money + stock change → confirm before firing, consistent with the existing delete-sale confirm modal on this page (a `restoringRow` ref + small confirm dialog). Confirm copy notes it adds a real sale and reduces stock by 1.
- **On success:** re-fetch the suppressed list (`fetchSuppressed(embeddedId)` → row vanishes) **and** re-fetch the machine's sales so the restored sale appears in the Sales tab (call the page's existing sales-load path, the same one that already runs `fetchSuppressed` at ~line 320). Surface errors with the page's existing error/toast mechanism.
- **i18n:** add keys under `machineDetail` in both `i18n/locales/en.json` and `de.json`: `suppressedRestore` (button), `suppressedRestoreConfirmTitle`, `suppressedRestoreConfirmBody`, `suppressedRestoreConfirmAction`, and a success/error message key. Match the tone of the existing `suppressed*` keys.

The button works on desktop and mobile (the PWA is used on both); swipe is reserved for native iOS per the platform's idiom.

### 3. iOS — "Duplicates" tab swipe-to-action (`ios/VMflow/...`)

**ViewModel** (`MachineDetailViewModel.swift`): add
```swift
func restoreSuppressed(_ id: UUID) async {
    do {
        struct Params: Encodable { let p_suppressed_id: UUID }
        try await client.rpc("restore_suppressed_sale", params: Params(p_suppressed_id: id)).execute()
        await loadDetail()   // refreshes trays, sales, AND suppressedSales
    } catch is CancellationError {
    } catch {
        self.error = error.localizedDescription
    }
}
```
`loadDetail()` already reloads sales and `loadSuppressedSales()`, so one call refreshes both surfaces.

**View** (`MachineDetailView.swift`) — convert the `suppressedTab` **populated branch** from `ScrollView { VStack { headerCard; LazyVStack(pinnedViews:) { Section… } } }` to a **`List` with `.listStyle(.plain)`**, following `DealsView`'s precedent of `List` + custom `Section` headers + `.swipeActions` on rows + `.listRowBackground(Color.clear)` / `.listRowSeparator(.hidden)` / `.listRowInsets` to keep the card look. **Two deliberate deviations from DealsView** (do not blindly copy it): use `.listStyle(.plain)` (DealsView uses `.insetGrouped`) to preserve the flat card look, and `allowsFullSwipe: false` (DealsView uses `true`) so a money/stock action can't fire on an accidental full swipe. Specifically:
- The header card ("N auto-removed" + hint), the loading `ProgressView`, and the empty state each become list rows (clear background, hidden separators) — or the loading/empty branches stay as today and only the populated list uses sections; both are acceptable as long as `.refreshable` and the header card are preserved.
- Day grouping is **unchanged in behavior**: reuse `groupSuppressedByDay` + the existing custom `DaySectionHeader(label:count:unit:"removed")` as each `Section`'s `header:`. `List` supports custom section header views (DealsView does exactly this).
- Each `SuppressedSaleRow` gets `.swipeActions(edge: .trailing, allowsFullSwipe: false)` with **one admin-only** green button — `Label("Take up as sale", systemImage: "checkmark.circle")`, `.tint(.green)`. `allowsFullSwipe: false` so an accidental full swipe can't fire a money/stock action; the user must tap the revealed button.
- Tapping the button presents a `.confirmationDialog` ("Take up as real sale? Adds a sale and reduces stock by 1.") → on confirm calls `viewModel.restoreSuppressed(sale.id)`.
- **Admin gating:** show the swipe action only when the user is an admin. Access the role via `@EnvironmentObject private var auth: AuthService` then `auth.role == .admin` — the same pattern `SettingsView` uses (there is **no `AuthService.shared` singleton**; it is an `ObservableObject` injected into the environment, and `MachineDetailView` already consumes other environment objects, e.g. `realtime: RealtimeService`). NOTE this is the **first sale-mutation admin gate in the iOS app** — `SettingsView` is currently the only reader of `auth.role`, and only to *display* it. The RPC enforces admin server-side regardless, so a non-admin who somehow triggers it gets a surfaced error rather than a silent change.

`SuppressedSaleRow`'s visual content is unchanged; only its container (List row) and the attached swipe action are new.

## Data flow (restore)

```
admin taps/swipes "Take up as sale"
  → confirm
  → rpc('restore_suppressed_sale', { p_suppressed_id })          [PWA / iOS]
      → i_am_admin() + company-ownership checks
      → INSERT sales (by embedded_id)  ─trigger→ resolve machine_id, tax, stock −1, product_id(current tray)
      → UPDATE sales.product_id = snapshot
      → DELETE suppressed_sales row
      → INSERT activity_log ('sale_restored', source: suppressed_restore)
      → RETURN new sale jsonb
  → client re-fetches suppressed list (row gone) + sales list (sale present)
```

## Backward compatibility / safety

- **Additive only.** New RPC + new UI controls + new i18n keys. No column drop/rename, no payload/topic change, no edge-function signature change. Old firmware and old clients are entirely unaffected (the RPC is a new, optional call).
- **Migration immutability respected** — brand-new migration file; idempotent `CREATE OR REPLACE FUNCTION` + explicit `GRANT`, safe to re-run via `update.sh` on every existing install.
- **RLS / least privilege** — admin-only (server-enforced) and company-scoped via `my_company_id()`; `authenticated` callers can only restore rows whose device belongs to their company.
- **Atomic** — single transaction; partial states impossible.
- **No double-effect** — restore consumes the suppressed row, so it cannot be restored twice; a second call with the same id raises "suppressed sale not found".

## Edge cases

- **Non-admin caller** → RPC raises; UI hides the action for non-admins (defense in depth).
- **Suppressed row already gone / bad id** → `NOT FOUND` → raise; client shows the error and the (stale) row drops on next fetch.
- **Device of a different company** → ownership check raises.
- **Null snapshot `product_id`** (legacy rows pre-`20260602140000`) → keep the trigger's current-tray derivation (no override).
- **`sale_seq` collision** (a sale with that exact `(embedded_id, sale_seq)` already exists — extremely unlikely, since the suppressed seq was never inserted) → the INSERT raises `23505`, the whole transaction aborts, nothing changes, the suppressed row stays. Safe (no silent duplicate); the admin can investigate. The plan need not add special handling beyond letting the error surface.
- **No matching tray for the item** → trigger logs to `stock_decrement_log` (`no_matching_tray`) and skips the decrement, exactly as a normal sale would; the sale is still recorded.

## Testing

- **SQL/RPC** (`Docker/supabase/tests/*.test.sql`, rolled-back txn, fake JWT): seed a device + machine + tray (stock N) + a `suppressed_sales` row with a product snapshot; call `restore_suppressed_sale`; assert: a `sales` row now exists with the snapshot `product_id`, the `suppressed_sales` row is gone, tray stock is N−1, an `activity_log` row with `action='sale_restored'` and `metadata->>'source' = 'suppressed_restore'` exists (assert via the jsonb field — there is no `source` column). Negative tests: non-admin raises; other-company row raises; missing id raises.
- **PWA** (vitest): unit-test `useSuppressedSales.restore` calls the RPC with `{ p_suppressed_id }` and throws on error (mock supabase). If feasible, a small component test that the restore button is admin-gated.
- **iOS:** manual Xcode build/run — Duplicates tab still day-grouped and styled like before (now a `List`), swipe reveals the green action for admins only, confirm → row leaves Duplicates and appears under Sales, stock drops by 1.

## Files touched

| File | Change |
|------|--------|
| `Docker/supabase/migrations/<new>_restore_suppressed_sale.sql` | New RPC `restore_suppressed_sale(uuid)` + GRANTs |
| `Docker/supabase/tests/restore_suppressed_sale.test.sql` (new) | SQL tests (happy path + negatives) |
| `management-frontend/app/composables/useSuppressedSales.ts` | Add `restore(id)` |
| `management-frontend/app/pages/machines/[id].vue` | Admin-only per-row restore button + confirm; refresh suppressed + sales on success |
| `management-frontend/app/composables/__tests__/useSuppressedSales.test.ts` (new or existing) | Unit test for `restore` |
| `management-frontend/i18n/locales/en.json`, `de.json` | Restore button/confirm/result keys under `machineDetail` |
| `ios/VMflow/ViewModels/MachineDetailViewModel.swift` | `restoreSuppressed(_:)` |
| `ios/VMflow/Views/Machines/MachineDetailView.swift` | `suppressedTab` populated branch → `List(.plain)` with `Section` headers + admin-only `.swipeActions` + `.confirmationDialog` |

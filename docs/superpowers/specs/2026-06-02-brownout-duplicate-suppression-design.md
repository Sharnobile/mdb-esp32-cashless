# Brownout duplicate-sale suppression (+ per-machine transparency UI)

**Date:** 2026-06-02
**Area:** `Docker/supabase` (DB + `mqtt-webhook`), `management-frontend` (PWA), `ios/VMflow` (native iOS)
**Type:** Additive backend dedup + new audit table + read-only UI in two clients

## Problem

Cash sales reach the device as MDB `CASH_SALE` commands carrying only
`itemPrice` + `itemNumber` — **no transaction id**
(`mdb-slave-esp32s3.c:900-910`). The firmware enqueues one sale per command and
`sale_queue` assigns a fresh monotonic `sale_seq` on every enqueue.

When the vend/cash mechanism's current inrush **browns out** the ESP, it reboots;
the MDB cashless session re-initialises and the VMC **re-delivers the
unacknowledged `CASH_SALE`**. The freshly-booted device (SNTP not yet synced →
`time_uncertain=true`) enqueues it **again as `seq N+1`** and publishes. Two
*different* seqs → the `UNIQUE(embedded_id, sale_seq)` idempotency (which only
stops re-delivery of the *same* seq) cannot merge them → a **duplicate sale row**.

Evidence (dev DB, prod-synced): the duplicate pairs are cash-channel, consecutive
seqs N/N+1, **100% `time_uncertain=true`** on the duplicate, with `created_at`
gaps averaging ~10-15 s (max ~19.5 s). The firmware cannot dedup at the MDB layer
(no txn id; a re-report is byte-identical to a genuine second identical sale)
except via the boot signal it already exposes: the `time_uncertain` flag.

## Goal

Stop counting these duplicates **automatically and safely**, and give per-machine
**transparency** into what was auto-removed (PWA + native iOS). Chosen handling
(decided): **auto-drop the suspect + write an audit row** (reversible, nothing
silently lost). UI: **read-only** count + list (no in-app restore).

## Non-goals / out of scope

- Cleaning up *existing* duplicates already in `sales` (the Nayax reconciliation
  tool already surfaces them as phantoms; a one-time cleanup is a separate task).
- The null-seq legacy duplicate class (v1 firmware, no seq) — separate.
- Firmware changes — rejected: no MDB txn id to dedup on, needs OTA, heuristic,
  and doesn't fix already-stored rows. The backend is the elegant, OTA-free lever.
- In-app "restore" of a suppressed sale — reversal of a (very rare) false positive
  is a manual/dev action from the audit table.

## Approach (chosen)

A **`time_uncertain`-gated near-duplicate guard in `mqtt-webhook`** that, on a
match, records the dropped sale in a new `suppressed_sales` audit table instead of
inserting it into `sales`. Rejected: a DB trigger/constraint (a time-window match
can't be a unique index; a trigger doing window-queries + audit-inserts is heavier
and harder to test/tune than app logic).

## Design

### 1. `suppressed_sales` audit table — new migration

```sql
create table if not exists public.suppressed_sales (
  id                uuid primary key default gen_random_uuid(),
  embedded_id       uuid not null references public.embeddeds(id) on delete cascade,
  item_number       integer,
  item_price        double precision,
  channel           text,
  sale_seq          bigint,
  device_created_at timestamptz,   -- the payload's device timestamp (may be unreliable)
  received_at       timestamptz not null default now(),
  matched_sale_id   uuid references public.sales(id) on delete set null,
  reason            text not null default 'time_uncertain_duplicate'
);
create index if not exists suppressed_sales_embedded_received_idx
  on public.suppressed_sales (embedded_id, received_at desc);

alter table public.suppressed_sales enable row level security;
grant select on public.suppressed_sales to authenticated;
grant select, insert, update, delete on public.suppressed_sales to service_role;

drop policy if exists suppressed_sales_select_own on public.suppressed_sales;
create policy suppressed_sales_select_own on public.suppressed_sales
  for select to authenticated
  using (exists (
    select 1 from public.embeddeds e
    where e.id = suppressed_sales.embedded_id
      and e.company = public.my_company_id()
  ));
```
Idempotent, additive, immutability-rule-compliant (new file). Mirrors the RLS
shape of `dex_snapshots` (`20260419000100`). (Confirm the `embeddeds` company
column name — `e.company` per `dex_snapshots` policy — during implementation.)

### 2. `mqtt-webhook` detection

In the `eventType === 'sale'` branch, **before** the existing `sales` insert, add
a gated check. Only fires when `timeUncertain === true`:

```
SUPPRESS_WINDOW_SECONDS = 30   // named, tunable constant

if (timeUncertain) {
  // recent near-duplicate on the same device/slot/price/channel?
  const { data: match } = await adminClient
    .from('sales')
    .select('id')
    .eq('embedded_id', embedded.id)
    .eq('item_number', itemNumber)
    .eq('item_price', salePrice)
    .eq('channel', channel)
    .gte('created_at', new Date(Date.parse(saleTime) - WINDOW_MS).toISOString())
    .lte('created_at', new Date(Date.parse(saleTime) + WINDOW_MS).toISOString())
    .limit(1)
    .maybeSingle()

  if (match) {
    await adminClient.from('suppressed_sales').insert([{
      embedded_id: embedded.id, item_number: itemNumber, item_price: salePrice,
      channel, sale_seq: saleSeq,
      // the RAW device timestamp, NOT saleTime (which was overwritten with
      // server time because time_uncertain) — preserve the device's own ts:
      device_created_at: timestampUnsigned > 0
        ? new Date(timestampUnsigned * 1000).toISOString() : null,
      received_at: new Date().toISOString(), matched_sale_id: match.id,
      reason: 'time_uncertain_duplicate',
    }])
    return new Response(JSON.stringify({ ok: true, suppressed: true }), { status: 200 })
  }
}
// …unchanged: existing sales insert with ON CONFLICT(embedded_id, sale_seq)…
```

- The window is **±`SUPPRESS_WINDOW_SECONDS`** around the incoming sale's
  `created_at` (handles minor device/server clock skew on the `f→t` pattern where
  the original carries device time).
- `salePrice` of the original and the re-report come from identical payload bytes
  → exact match holds; match on the same `salePrice` value the webhook computes.
- **Normal sales (`time_uncertain=false`) skip the query entirely** → zero impact
  on the hot path and on legitimate rapid repeat sales.
- The existing seq `ON CONFLICT` path is untouched and still runs for everything
  that isn't suppressed (covers same-seq replay).
- **Window-miss is a safe false-negative:** if the original was stored with a
  *device* timestamp and the re-report arrives >30 s (server time) after that
  `created_at` (very slow reconnect/SNTP), the query misses and the duplicate
  inserts normally — it then shows up as a phantom in the Nayax reconciliation
  tool for manual review. This is a *miss*, never a wrong drop. Worth a one-line
  code comment next to `SUPPRESS_WINDOW_SECONDS`.

**Testability:** extract a pure `decideSuppress(incoming, recentMatches, windowMs)`
(returns boolean) where `incoming` carries `{ timeUncertain, createdAtMs }` and
`recentMatches` is the candidate list; the DB query stays in the handler. Unit-test
the predicate (Deno, alongside `mdb-log.test.ts`):
- `time_uncertain=false` + match present → **insert** (false).
- `time_uncertain=true` + match within window → **suppress** (true).
- `time_uncertain=true` + match outside window → **insert** (false).
- `time_uncertain=true` + no match → **insert** (false).

### 3. PWA — `/machines/[id]` Device Health tab (read-only)

- New composable **`useSuppressedSales()`** mirroring `useMdbLog`:
  `from('suppressed_sales').select('*').eq('embedded_id', embeddedId)
  .order('received_at', { ascending: false })` with the same paginated
  `fetchLogs` / `fetchMore` shape.
- In the **Device Health** tab, an "Auto-removed duplicates" card: a **count** plus
  a list (received time via `formatDateTime`, slot, price via `formatCurrency`,
  channel, and a one-line "likely brownout re-report" note). Optionally show the
  device's `last_restart_reason` / `last_restart_at` (already selected on the page)
  as context. Read-only; no actions.
- i18n keys (en/de, German informal *du*): card title, the per-row "reason" label,
  empty state, count label.

### 4. iOS — `MachineDetailView` (read-only)

- New model `ios/VMflow/Models/SuppressedSale.swift` (`Codable, Identifiable,
  Equatable`; `CodingKeys` snake_case → camelCase; a `formattedPrice` helper),
  mirroring `Sale.swift`.
- `MachineDetailViewModel.loadSuppressedSales()` mirroring `loadSales()`:
  `client.from("suppressed_sales").select(...).eq("embedded_id", value:
  machine.embedded?.uuidString ?? "").order("received_at", ascending: false)
  .limit(100)`. Add a `@Published var suppressedSales` + call it from the detail
  load.
- A read-only section/tab in `MachineDetailView` showing the count + a
  `SuppressedSaleRow` list (adapt `SaleRow`: time from `receivedAt`, slot, price,
  channel badge, "auto-removed" note). Placement: a section in the detail (or a
  3rd segmented tab) — match whatever reads cleanest against current structure.
- **Implementation caution:** `MachineDetailView.swift` / `MachineDetailViewModel.swift`
  and other `ios/` files currently have **uncommitted changes from other work**.
  The iOS slice must be applied so it does not clobber those — ideally land/commit
  the in-flight iOS work first, or apply the iOS changes as a clearly-scoped,
  additive diff and reconcile by hand. This is the riskiest part to sequence.

## Cross-cutting

- **Backward compatibility:** v1/old firmware never sets `time_uncertain` → the
  guard never fires → fully additive; no other insert path or caller changes.
- **Residual false-positive risk:** two *genuine* identical sales (same
  slot/price/channel) within 30 s **and** both while the clock is unsynced
  (a brief post-boot window) → the second is wrongly dropped. Extremely rare;
  it's recorded in `suppressed_sales` → visible and reversible.
- **Two environments:** pure SQL migration + edge-function code + frontend + iOS;
  **no** new env vars / edge functions / `config.toml` entries. Migration applies
  to prod via `update.sh` and to dev via `supabase --workdir Docker migration up`.

## Testing / verification

- **Migration:** apply to dev; `psql` checks — table exists, RLS policy present;
  insert a row and confirm an authenticated query is company-scoped.
- **Webhook:** Deno unit test for `decideSuppress` (the four cases above).
- **End-to-end (dev, manual/psql):** seed a `sales` row, then POST a forwarded
  `time_uncertain` sale matching it within 30 s → assert no new `sales` row and one
  `suppressed_sales` row with the right `matched_sale_id`; POST a non-matching /
  non-`time_uncertain` sale → assert it inserts normally.
- **PWA:** `useSuppressedSales` mirrors the tested `useMdbLog` pattern; the card is
  verified via preview if reachable (machine detail Device Health tab).
- **iOS:** manual build/run verification (no iOS test harness).

## Files touched

| File | Change |
|------|--------|
| `Docker/supabase/migrations/<new>_suppressed_sales.sql` | new `suppressed_sales` table + RLS |
| `Docker/supabase/functions/mqtt-webhook/index.ts` | `time_uncertain`-gated near-dup guard → suppress + audit; extract `decideSuppress` |
| `Docker/supabase/functions/mqtt-webhook/*.test.ts` | Deno unit test for `decideSuppress` |
| `management-frontend/app/composables/useSuppressedSales.ts` | new composable (mirror `useMdbLog`) |
| `management-frontend/app/pages/machines/[id].vue` | Device Health "auto-removed duplicates" card |
| `management-frontend/i18n/locales/en.json`, `…/de.json` | UI strings |
| `ios/VMflow/Models/SuppressedSale.swift` | new model |
| `ios/VMflow/ViewModels/MachineDetailViewModel.swift` | `loadSuppressedSales()` + state |
| `ios/VMflow/Views/Machines/MachineDetailView.swift` | read-only suppressed-duplicates section + row |

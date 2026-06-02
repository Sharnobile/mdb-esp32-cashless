# Brownout Duplicate-Sale Suppression — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-drop brownout re-report duplicate sales in `mqtt-webhook` (gated on `time_uncertain` + a 30 s same-key window), record each into a new `suppressed_sales` audit table, and surface a read-only per-machine "auto-removed duplicates" view in the PWA and native iOS.

**Architecture:** A `time_uncertain`-gated near-duplicate guard runs before the existing `sales` insert in the webhook; on a match it writes a `suppressed_sales` audit row and skips the insert. The match decision is a pure, unit-tested function. Two clients read the audit table per `embedded_id` (PWA composable + Device Health card; iOS model + detail section).

**Tech Stack:** Supabase Postgres (plpgsql, RLS), Deno edge function (`mqtt-webhook`), Nuxt 4 + Vue 3 `<script setup>` + TS (PWA), `@nuxtjs/i18n` (en/de), SwiftUI + supabase-swift (iOS).

**Spec:** `docs/superpowers/specs/2026-06-02-brownout-duplicate-suppression-design.md`

**Skills:** @superpowers:test-driven-development (Task 1.2), @superpowers:verification-before-completion before claiming done.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `Docker/supabase/migrations/20260602130000_suppressed_sales.sql` | DB | NEW: `suppressed_sales` table + RLS |
| `Docker/supabase/functions/mqtt-webhook/suppress.ts` | pure decision | NEW: `decideSuppress` + `SUPPRESS_WINDOW_MS` |
| `Docker/supabase/functions/mqtt-webhook/suppress.test.ts` | tests | NEW: Deno unit tests |
| `Docker/supabase/functions/mqtt-webhook/index.ts` | webhook | wire the guard before the `sales` insert |
| `management-frontend/app/composables/useSuppressedSales.ts` | PWA data | NEW: mirror `useMdbLog` |
| `management-frontend/app/pages/machines/[id].vue` | PWA UI | Device Health "auto-removed duplicates" card |
| `management-frontend/i18n/locales/en.json`, `…/de.json` | strings | UI strings |
| `ios/VMflow/Models/SuppressedSale.swift` | iOS model | NEW |
| `ios/VMflow/ViewModels/MachineDetailViewModel.swift` | iOS data | `loadSuppressedSales()` + state (surgical) |
| `ios/VMflow/Views/Machines/MachineDetailView.swift` | iOS UI | read-only section (surgical) |

**Commit scoping (every task):** stage ONLY the files that task changes — **never `git add -A`**. The working tree has unrelated changes (`README.md`, `docs/screenshots/`, `MMM-VMflow/`, `tmp/`, and **in-flight `ios/` work**) that must NOT be swept in. Branch: stay on `main`.

---

## Chunk 1: Backend (migration + webhook guard + test)

### Task 1.1: `suppressed_sales` migration

**Files:** Create `Docker/supabase/migrations/20260602130000_suppressed_sales.sql`

- [ ] **Step 1: Create the migration** with this content:

```sql
-- =========================================================
-- suppressed_sales: audit of auto-dropped brownout duplicate sales
--
-- mqtt-webhook drops a sale (instead of inserting into `sales`) when it is
-- time_uncertain AND near-duplicates a recent sale on the same device/slot/
-- price/channel (brownout re-report). The dropped row is recorded here so the
-- action is transparent and reversible. Read-only in the clients.
-- Idempotent / additive.
-- =========================================================
create table if not exists public.suppressed_sales (
  id                uuid primary key default gen_random_uuid(),
  embedded_id       uuid not null references public.embeddeds(id) on delete cascade,
  item_number       integer,
  item_price        double precision,
  channel           text,
  sale_seq          bigint,
  device_created_at timestamptz,
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
  using (
    exists (
      select 1 from public.embeddeds e
      where e.id = suppressed_sales.embedded_id
        and e.company = public.my_company_id()
    )
  );

comment on table public.suppressed_sales is
  'Audit of sales auto-dropped by mqtt-webhook as suspected brownout re-reports (time_uncertain + near-duplicate). Read-only transparency; reversible by re-inserting from this row.';
```

- [ ] **Step 2: Apply to dev** — `supabase --workdir Docker migration up` (per memory: `--workdir Docker`, never `cd`; NEVER `supabase db reset`). Expected: applies with no error.

- [ ] **Step 3: Verify table + RLS via psql**

```bash
docker exec -i supabase_db_mdb-esp32-cashless psql -U postgres -d postgres -c "\d public.suppressed_sales" -c "SELECT polname, polcmd FROM pg_policy WHERE polrelid='public.suppressed_sales'::regclass;"
```
Expected: the table with all columns; a `suppressed_sales_select_own` SELECT policy.

- [ ] **Step 4: Commit**

```bash
git add Docker/supabase/migrations/20260602130000_suppressed_sales.sql
git commit -m "feat(db): suppressed_sales audit table for brownout dedup"
```

### Task 1.2: `decideSuppress` pure function + Deno tests (TDD)

**Files:** Create `Docker/supabase/functions/mqtt-webhook/suppress.ts` + `…/suppress.test.ts`

- [ ] **Step 1: Write the failing test** — `suppress.test.ts`:

```ts
// Use the same std-assert specifier the repo's existing mdb-log.test.ts uses.
import { assertEquals } from "jsr:@std/assert";
import { decideSuppress, SUPPRESS_WINDOW_MS } from "./suppress.ts";

const T = 1_700_000_000_000; // fixed base ms

Deno.test("not suppressed when time_uncertain is false (even with a match)", () => {
  assertEquals(
    decideSuppress({ timeUncertain: false, createdAtMs: T }, [{ id: "a", createdAtMs: T }]),
    null,
  );
});

Deno.test("suppressed (returns matched id) when time_uncertain + candidate within window", () => {
  assertEquals(
    decideSuppress({ timeUncertain: true, createdAtMs: T }, [{ id: "a", createdAtMs: T + 5_000 }]),
    "a",
  );
});

Deno.test("not suppressed when the only candidate is outside the window", () => {
  assertEquals(
    decideSuppress({ timeUncertain: true, createdAtMs: T }, [{ id: "a", createdAtMs: T + SUPPRESS_WINDOW_MS + 1 }]),
    null,
  );
});

Deno.test("not suppressed when there are no candidates", () => {
  assertEquals(decideSuppress({ timeUncertain: true, createdAtMs: T }, []), null);
});

Deno.test("window is symmetric (candidate slightly before also matches)", () => {
  assertEquals(
    decideSuppress({ timeUncertain: true, createdAtMs: T }, [{ id: "b", createdAtMs: T - 10_000 }]),
    "b",
  );
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Docker/supabase/functions/mqtt-webhook && deno test suppress.test.ts`
Expected: FAIL — `suppress.ts` / `decideSuppress` not found.

- [ ] **Step 3: Implement** — `suppress.ts`:

```ts
/** Match window for brownout-duplicate suppression. Tunable. See spec. */
export const SUPPRESS_WINDOW_MS = 30_000;

export interface SuppressCandidate {
  id: string;
  createdAtMs: number;
}

/**
 * Decide whether an incoming sale is a brownout re-report that should be
 * suppressed (auto-dropped) instead of inserted.
 *
 * Returns the matched existing sale's id (to store as matched_sale_id) or
 * null to insert normally.
 *
 * Safety: only `time_uncertain` sales are ever suppressed — a normal sale
 * (synced clock) is always inserted, even if an identical recent sale exists.
 * Among time_uncertain sales, suppress when a same-key candidate (the caller
 * pre-filters by embedded_id/item_number/item_price/channel) falls within
 * ±windowMs of the incoming created_at.
 */
export function decideSuppress(
  incoming: { timeUncertain: boolean; createdAtMs: number },
  candidates: SuppressCandidate[],
  windowMs: number = SUPPRESS_WINDOW_MS,
): string | null {
  if (!incoming.timeUncertain) return null;
  for (const c of candidates) {
    if (Math.abs(c.createdAtMs - incoming.createdAtMs) <= windowMs) return c.id;
  }
  return null;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd Docker/supabase/functions/mqtt-webhook && deno test suppress.test.ts`
Expected: PASS (5 tests). (If the std assert URL differs from the repo's existing test, match what `mdb-log.test.ts` imports.)

- [ ] **Step 5: Commit**

```bash
git add Docker/supabase/functions/mqtt-webhook/suppress.ts Docker/supabase/functions/mqtt-webhook/suppress.test.ts
git commit -m "feat(webhook): pure decideSuppress for brownout duplicate detection"
```

### Task 1.3: Wire the guard into `mqtt-webhook`

**Files:** Modify `Docker/supabase/functions/mqtt-webhook/index.ts`

- [ ] **Step 1: Add the import** near the top of `index.ts`:
```ts
import { decideSuppress, SUPPRESS_WINDOW_MS, type SuppressCandidate } from "./suppress.ts";
```

- [ ] **Step 2: Insert the guard** inside the `if (eventType === 'sale') { … }` branch, **after** `saleTime` is computed and **before** the existing `await adminClient.from('sales').insert([{ … }])`:

```ts
      // Brownout duplicate guard: a re-reported cash sale after a reboot arrives
      // time_uncertain and re-enqueued with a NEW seq (so the seq idempotency
      // below can't catch it). Only time_uncertain sales are checked, so normal
      // rapid repeat sales are never affected. Window ±SUPPRESS_WINDOW_MS;
      // misses (very slow reconnect) are safe — they fall through to insert and
      // surface as phantoms in the Nayax reconciliation tool.
      if (timeUncertain) {
        const incomingMs = Date.parse(saleTime);
        const sinceIso = new Date(incomingMs - SUPPRESS_WINDOW_MS - 60_000).toISOString();
        const { data: candRows } = await adminClient
          .from('sales')
          .select('id, created_at')
          .eq('embedded_id', embedded.id)
          .eq('item_number', itemNumber)
          .eq('item_price', salePrice)
          .eq('channel', channel)
          .gte('created_at', sinceIso)
          .order('created_at', { ascending: false })
          .limit(20);
        const candidates: SuppressCandidate[] = (candRows ?? []).map(
          (r: { id: string; created_at: string }) => ({ id: r.id, createdAtMs: Date.parse(r.created_at) }),
        );
        const matchedId = decideSuppress({ timeUncertain, createdAtMs: incomingMs }, candidates, SUPPRESS_WINDOW_MS);
        if (matchedId) {
          await adminClient.from('suppressed_sales').insert([{
            embedded_id: embedded.id,
            item_number: itemNumber,
            item_price: salePrice,
            channel,
            sale_seq: saleSeq,
            // raw device timestamp, NOT saleTime (which is server time here)
            device_created_at: timestampUnsigned > 0 ? new Date(timestampUnsigned * 1000).toISOString() : null,
            received_at: new Date().toISOString(),
            matched_sale_id: matchedId,
            reason: 'time_uncertain_duplicate',
          }]);
          return new Response(JSON.stringify({ ok: true, suppressed: true }), { status: 200 });
        }
      }
```
(The variable names `timeUncertain`, `saleSeq`, `salePrice`, `channel`, `itemNumber`, `timestampUnsigned`, `embedded`, `saleTime` all already exist in scope at this point — confirm against the current source. Do NOT change the existing insert / `ON CONFLICT` 23505 handling that follows.)

- [ ] **Step 2b: Deploy the function locally so dev reflects it** — `supabase --workdir Docker functions serve` is not required for the psql test, but to e2e-test via HTTP the function must be served. For this plan the e2e check uses a direct insert simulation (Step 3), so a redeploy isn't strictly needed for verification. (If serving: `supabase --workdir Docker functions serve mqtt-webhook`.)

- [ ] **Step 3: End-to-end verify the suppression path against the dev DB** (simulates what the webhook does, in a rolled-back transaction so dev data is untouched):

```bash
docker exec -i supabase_db_mdb-esp32-cashless psql -U postgres -d postgres <<'SQL'
\set ON_ERROR_STOP on
BEGIN;
-- a device that has at least one sale
SELECT embedded_id AS eid, item_number AS itm, item_price AS prc, channel AS chn, created_at AS ts
FROM public.sales WHERE embedded_id IS NOT NULL ORDER BY created_at DESC LIMIT 1 \gset
-- simulate the webhook's candidate query (same key, within ~30s)
SELECT count(*) AS candidates_within_30s
FROM public.sales
WHERE embedded_id = :'eid' AND item_number = :itm AND item_price = :prc AND channel = :'chn'
  AND created_at >= (:'ts'::timestamptz - interval '30 seconds')
  AND created_at <= (:'ts'::timestamptz + interval '30 seconds');
-- simulate recording a suppression for that match
INSERT INTO public.suppressed_sales (embedded_id, item_number, item_price, channel, reason, matched_sale_id)
SELECT :'eid', :itm, :prc, :'chn', 'time_uncertain_duplicate',
       (SELECT id FROM public.sales WHERE embedded_id=:'eid' AND item_number=:itm ORDER BY created_at DESC LIMIT 1);
SELECT count(*) AS suppressed_rows FROM public.suppressed_sales WHERE embedded_id=:'eid';
ROLLBACK;
SQL
```
Expected: `candidates_within_30s >= 1`, the insert succeeds, `suppressed_rows >= 1`. Rolled back — no dev mutation. (This validates the table + the candidate-matching SQL shape; `decideSuppress`'s gate/window logic is covered by the unit tests.)

- [ ] **Step 4: Commit**

```bash
git add Docker/supabase/functions/mqtt-webhook/index.ts
git commit -m "feat(webhook): drop brownout duplicate re-reports into suppressed_sales"
```

> **Chunk 1 gate:** `deno test suppress.test.ts` green; migration applied + RLS verified; e2e psql simulation passes. The webhook still inserts normal + non-matching + non-time_uncertain sales unchanged.

---

## Chunk 2: PWA — read-only Device Health surfacing

### Task 2.1: `useSuppressedSales` composable

**Files:** Create `management-frontend/app/composables/useSuppressedSales.ts`

- [ ] **Step 1: Read `app/composables/useMdbLog.ts`** to copy its exact shape (state refs, `fetchLogs(embeddedId)`, `fetchMore(embeddedId)`, page size, loading/hasMore). Mirror it for `suppressed_sales`:

```ts
import { ref } from 'vue'
import { useSupabaseClient } from '#imports'

export interface SuppressedSale {
  id: string
  embedded_id: string
  item_number: number | null
  item_price: number | null
  channel: string | null
  sale_seq: number | null
  device_created_at: string | null
  received_at: string
  matched_sale_id: string | null
  reason: string
}

const PAGE = 50

export function useSuppressedSales() {
  // Capture the client once (like useMdbLog) — calling useSupabaseClient()
  // after an await would be outside the Nuxt sync context.
  const supabase = useSupabaseClient()
  const rows = ref<SuppressedSale[]>([])
  const loading = ref(false)
  const hasMore = ref(false)

  async function fetchRows(embeddedId: string) {
    loading.value = true
    try {
      const { data, error } = await (supabase as any)
        .from('suppressed_sales')
        .select('*')
        .eq('embedded_id', embeddedId)
        .order('received_at', { ascending: false })
        .range(0, PAGE - 1)
      if (error) throw error
      rows.value = (data ?? []) as SuppressedSale[]
      hasMore.value = rows.value.length === PAGE
    } finally {
      loading.value = false
    }
  }

  async function fetchMore(embeddedId: string) {
    if (loading.value || !hasMore.value) return
    loading.value = true
    try {
      const from = rows.value.length
      const { data, error } = await (supabase as any)
        .from('suppressed_sales')
        .select('*')
        .eq('embedded_id', embeddedId)
        .order('received_at', { ascending: false })
        .range(from, from + PAGE - 1)
      if (error) throw error
      const next = (data ?? []) as SuppressedSale[]
      rows.value = [...rows.value, ...next]
      hasMore.value = next.length === PAGE
    } finally {
      loading.value = false
    }
  }

  return { rows, loading, hasMore, fetchRows, fetchMore }
}
```
(Align casts/imports with `useMdbLog.ts` — e.g. if it casts the client differently, match it.)

- [ ] **Step 2: Verify the suite still compiles/passes**

Run: `cd management-frontend && npx vitest run`
Expected: green (composable isn't unit-tested; this guards against a syntax/type regression in scope).

- [ ] **Step 3: Commit**

```bash
git add app/composables/useSuppressedSales.ts
git commit -m "feat(pwa): useSuppressedSales composable"
```

### Task 2.2: i18n strings

**Files:** Modify `management-frontend/i18n/locales/en.json`, `…/de.json`

- [ ] **Step 1: Add keys** under the machine-detail / device-health namespace used by `pages/machines/[id].vue` (inspect the file to find the right parent key, e.g. `machines.*`; place a `suppressed` group there). German informal *du*.
  - en: `"suppressedTitle": "Auto-removed duplicates"`, `"suppressedHint": "Sales auto-dropped as suspected brownout re-reports."`, `"suppressedEmpty": "None — no duplicates auto-removed."`, `"suppressedCount": "{n} auto-removed"`, `"suppressedReason": "likely brownout re-report"`.
  - de: `"suppressedTitle": "Automatisch entfernte Duplikate"`, `"suppressedHint": "Verkäufe, die als vermutliche Brownout-Doppelmeldungen automatisch verworfen wurden."`, `"suppressedEmpty": "Keine — es wurden keine Duplikate automatisch entfernt."`, `"suppressedCount": "{n} automatisch entfernt"`, `"suppressedReason": "vermutlich Brownout-Doppelmeldung"`.

- [ ] **Step 2: Validate JSON**

Run: `cd management-frontend && node -e "JSON.parse(require('fs').readFileSync('i18n/locales/en.json','utf8'));JSON.parse(require('fs').readFileSync('i18n/locales/de.json','utf8'));console.log('ok')"`
Expected: `ok`

- [ ] **Step 3: Commit**

```bash
git add i18n/locales/en.json i18n/locales/de.json
git commit -m "i18n(pwa): auto-removed duplicates strings"
```

### Task 2.3: Device Health card

**Files:** Modify `management-frontend/app/pages/machines/[id].vue`

- [ ] **Step 1: Wire the composable** in `<script setup>`: instantiate `const { rows: suppressedRows, fetchRows: fetchSuppressed } = useSuppressedSales()`, and call `fetchSuppressed(embeddedId)` where the page already loads per-device data (where `machine.value?.embeddeds?.id` is known — mirror how `useMdbLog`'s `fetchLogs` is invoked).

- [ ] **Step 2: Add the card** inside the Device Health tab block (the `tab === 'health'` section, ~line 2089). Read-only: a header with count (`t('…suppressedCount', { n: suppressedRows.length })`), the hint, an empty state, and a list — each row: `formatDateTime(row.received_at, locale)`, `Slot {{ row.item_number }}`, `formatCurrency(row.item_price, locale)`, channel, and the `suppressedReason` note. Follow the existing card/list markup in that tab (use the same Tailwind classes as the neighbouring health cards). No actions.

- [ ] **Step 3: Verify**

Run: `cd management-frontend && npx vitest run` (green) — and a typecheck spot check: `npx nuxi typecheck 2>&1 | grep -E "useSuppressedSales|machines/\[id\]"` → no NEW errors attributable to these changes.

- [ ] **Step 4: Commit**

```bash
git add app/pages/machines/[id].vue
git commit -m "feat(pwa): device-health auto-removed-duplicates card"
```

> **Chunk 2 gate:** vitest green; no new typecheck errors in the touched files. Preview verification of the card is best-effort (the card is reachable on the machine-detail Device Health tab; the orchestrator may verify via preview if a device with suppressed rows exists in dev).

---

## Chunk 3: iOS — read-only surfacing (ADDITIVE / surgical; protect in-flight work)

> **CRITICAL — uncommitted iOS work:** `MachineDetailViewModel.swift`, `MachineDetailView.swift`, and other `ios/` files have uncommitted changes from other work. Rules for this chunk:
> - The NEW file (`SuppressedSale.swift`) is committed normally (it's clean).
> - For the two EDITED files, make **minimal, surgical, additive** edits only. **Do NOT `git add` or commit those two files** — leave the edits in the working tree for the user to review and commit together with their in-flight iOS work. Report the exact diffs you applied.
> - Never `git add -A`.

### Task 3.1: `SuppressedSale` model

**Files:** Create `ios/VMflow/Models/SuppressedSale.swift`

- [ ] **Step 1: Read `ios/VMflow/Models/Sale.swift`** to match conventions, then create:

```swift
import Foundation

struct SuppressedSale: Codable, Identifiable, Equatable {
    let id: UUID
    let embeddedId: UUID
    let itemNumber: Int?
    let itemPrice: Double?
    let channel: String?
    let saleSeq: Int?
    let deviceCreatedAt: Date?
    let receivedAt: Date
    let matchedSaleId: UUID?
    let reason: String

    enum CodingKeys: String, CodingKey {
        case id, channel, reason
        case embeddedId = "embedded_id"
        case itemNumber = "item_number"
        case itemPrice = "item_price"
        case saleSeq = "sale_seq"
        case deviceCreatedAt = "device_created_at"
        case receivedAt = "received_at"
        case matchedSaleId = "matched_sale_id"
    }

    var formattedPrice: String {
        guard let p = itemPrice else { return "—" }
        return String(format: "%.2f €", p)
    }
}
```

- [ ] **Step 2: Commit (this new file only)**

```bash
git add ios/VMflow/Models/SuppressedSale.swift
git commit -m "feat(ios): SuppressedSale model"
```

### Task 3.2: `loadSuppressedSales()` in the view model (surgical, NOT committed)

**Files:** Modify `ios/VMflow/ViewModels/MachineDetailViewModel.swift` — leave uncommitted (see chunk header).

- [ ] **Step 1: Add published state** next to the other `@Published` arrays:
```swift
@Published var suppressedSales: [SuppressedSale] = []
```

- [ ] **Step 2: Add a load function** mirroring `loadSales()`:
```swift
private func loadSuppressedSales() async throws {
    guard let embeddedId = machine.embedded?.uuidString else { suppressedSales = []; return }
    suppressedSales = try await client
        .from("suppressed_sales")
        .select("id, embedded_id, item_number, item_price, channel, sale_seq, device_created_at, received_at, matched_sale_id, reason")
        .eq("embedded_id", value: embeddedId)
        .order("received_at", ascending: false)
        .limit(100)
        .execute()
        .value
}
```

- [ ] **Step 3: Call it** from the same place `loadSales()` is invoked in the detail-load flow (mirror that call). Keep it best-effort (don't fail the whole load if it throws — match how the VM handles per-section errors).

- [ ] **Step 4: Report the diff** (do NOT commit). Confirm it compiles if an Xcode/`swift build` is available; otherwise leave for the user.

### Task 3.3: Read-only section in the detail view (surgical, NOT committed)

**Files:** Modify `ios/VMflow/Views/Machines/MachineDetailView.swift` — leave uncommitted (see chunk header).

- [ ] **Step 1: Add a `SuppressedSaleRow`** (adapt `SaleRow`): show `receivedAt` (HH:mm:ss via an inline `DateFormatter`), `formattedPrice`, a channel capsule, `Slot \(itemNumber)`, and a small "auto-removed" / reason caption. Read-only (no `onTapGesture` action).

- [ ] **Step 2: Surface it** — either a collapsible section within the existing detail (preferred: an additive `Section`/`VStack` below the sales content) OR a 3rd segmented tab (`.tag(2)`), whichever is the smallest additive change against the file's CURRENT (uncommitted) structure. Show a header with the count and the hint; render `ForEach(viewModel.suppressedSales) { SuppressedSaleRow(sale: $0) }`; show an empty-state when none.

- [ ] **Step 3: Report the diff** (do NOT commit). Note clearly that Tasks 3.2 + 3.3 edits are left in the working tree for the user to reconcile + commit with their in-flight iOS changes.

> **Chunk 3 gate:** `SuppressedSale.swift` committed; the two edited files report clean, additive diffs left uncommitted for the user. If a Swift build is available, it compiles; otherwise the user verifies in Xcode.

---

## Done criteria
- `deno test suppress.test.ts` green; migration applied to dev + RLS verified; e2e psql suppression simulation passes.
- `npx vitest run` green; no new typecheck errors in the touched PWA files.
- PWA Device Health shows a read-only "auto-removed duplicates" card (count + list); en/de strings present.
- iOS: `SuppressedSale.swift` committed; ViewModel + View edits applied as surgical additive diffs, left uncommitted for the user to reconcile with in-flight iOS work; builds in Xcode.
- Backward-compat intact: v1 firmware (no `time_uncertain`) never triggers the guard; normal sales unaffected; existing seq `ON CONFLICT` path unchanged.
- Unrelated working-tree files (README.md, docs/screenshots/, MMM-VMflow/, tmp/, and the user's other ios/ changes) untouched / not swept into our commits.
```

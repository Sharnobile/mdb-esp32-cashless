# Nayax Sales Reconciliation — Design Spec

**Date:** 2026-05-20
**Author:** Lucien Kerl (with Claude)
**Status:** Draft → User review pending

## Goal

Add an "Analyze" feature to the management frontend that lets an admin upload a Nayax sales export (`.xlsx`) and surfaces the differences between Nayax's transaction log and our own `sales` table. The user reports that 1–3 sales per period are missing between the two systems, and needs a diagnostic tool that pinpoints which specific sales drifted.

The result of the comparison is shown in three buckets — matched / missing-in-DB / ghost-in-DB — with bulk import of missing sales and per-row deletion of ghost sales.

## Non-goals

- Persistent reconciliation history (analysis is ephemeral; closing the page discards it).
- Refund / negative-amount lines in the Nayax export (v1 considers positive sale rows only).
- Auto-syncing Nayax in real time. Upload is on-demand.
- Cross-company Nayax accounts (each company maps its own Nayax machine IDs).

## Background — Nayax export format

The user provided a real export at `tmp/nayax-sale.xlsx`. Inspection of `xl/worksheets/sheet1.xml` confirms the layout:

- **Row 1**: Title cell, format `Dynamische Transaktionsüberwachung\nGesuchter Datumsbereich: DD.MM.YYYY HH:MM:SS - DD.MM.YYYY HH:MM:SS`.
- **Row 2**: Header row, German labels.
- **Rows 3..n-1**: Data rows.
- **Row n**: A `Total` summary row (currency column reads "Total"; numeric columns hold sums).

Columns (German labels, 1-indexed):

| # | Label                          | Type    | Sample                                    | Used as |
|---|--------------------------------|---------|-------------------------------------------|---------|
| 1 | Standort-ID                    | int     | `6`                                       | filter (skip if empty → Total row) |
| 2 | Transaktions-ID                | string  | `62968009978`                             | display only (not a match key) |
| 3 | Zahlungsmethoden-ID            | int     | `3`                                       | unused |
| 4 | Währung                        | string  | `EUR`                                     | filter (`Total` here = footer row) |
| 5 | Maschinenname                  | string  | `Niedernhall Frankeneck`                  | display + mapping fallback |
| 6 | Produktgruppe                  | string  | `Getränke`                                | display |
| 7 | Payment Method (Source)        | string  | `Cash`, `Credit Card(CLS)`                | derives `sales.channel` on import |
| 8 | Produktname                    | string  | `Powerade Sports Mountain Blast`          | display |
| 9 | Maschinen-Begleichszeit        | string  | `31.03.2026 21:46:09`                     | **match: timestamp** (local TZ) |
| 10 | Zu begleichender Wert          | number  | `2.5000`                                  | **match: price** (gross, EUR) |
| 11 | MwSt.                          | number  | `19.00`                                   | unused |
| 12 | MwSt. Betrag                   | number  | `0.4000`                                  | unused |
| 13 | Netto Preis                    | number  | `2.1000`                                  | unused |
| 14 | Produktauswahl-Informationen   | string  | `Powerade Sports Mountain Blast(58  2.50)` | **match: item_number** (regex parse) |
| 15 | Maschinen-ID                   | string/int | `92700604`                             | **match: machine** (via persistent mapping) |

The MDB selection code (slot/item number) is embedded inside `Produktauswahl-Informationen` between parentheses: `<product name>(<item_number>  <price>)`. Regex `/\((\d+)\s+[\d.,]+\)/` captures the slot number from group 1.

Timestamps in `Maschinen-Begleichszeit` are formatted `DD.MM.YYYY HH:MM:SS` and represent **local time in the Nayax operator's configured timezone**. For this user that is Europe/Berlin. DST applies — e.g. `31.03.2026 21:46:09` is after CEST starts (DST began 2026-03-29) so the UTC equivalent is `2026-03-31T19:46:09Z`.

## Architecture decision: client-side analysis

The parsing, matching, and result rendering all run in the browser. We do **not** add a new edge function.

Rationale:
- Mirrors the existing pattern: `/reports` already does all CSV exports client-side; `useImportProducts` already pulls `xlsx` lazily.
- A monthly Nayax export is on the order of a few hundred to a few thousand rows — well within browser capability.
- The two mutating actions (import-missing, delete-ghost) reuse existing RPCs (`insert_manual_sale`, `delete_sale_and_restore_stock`) that already enforce RLS and stock-restoration semantics. No new write surface is added.
- No new edge function = no new deployment file in `config.toml`, no new secret, no new failure mode in dev vs. prod.

Rejected alternatives:
- **Edge function** for server-side matching: adds deployment surface and a new RLS-protected read path for no scaling benefit at expected volumes.
- **Hybrid** (parse client, match server): loses the client-only simplicity without gaining the persistence benefit of a full server approach.

## Database changes

One new column on the existing `vendingMachine` table. No new tables in v1.

### Migration `YYYYMMDDHHMMSS_vending_machine_nayax_id.sql`

```sql
ALTER TABLE public."vendingMachine"
  ADD COLUMN IF NOT EXISTS nayax_machine_id text;

CREATE INDEX IF NOT EXISTS vending_machine_nayax_id_idx
  ON public."vendingMachine" (nayax_machine_id)
  WHERE nayax_machine_id IS NOT NULL;
```

- **Nullable** — pre-existing machines without a Nayax pairing keep working.
- **No UNIQUE constraint** — Nayax IDs are globally unique within Nayax but we don't want a cross-company unique error if two companies happen to have the same Nayax serial in their data.
- **Sparse partial index** — speeds up lookup by Nayax ID without indexing the (large) majority of rows where it's NULL.
- **Backward compat** — additive change. Existing firmware doesn't read this column; existing frontend code paths ignore unknown columns when they `select('*')`.

RLS: `vendingMachine` already has full row-level policies; the new column is automatically covered.

## Components and data flow

### File structure

```
management-frontend/
  app/
    composables/
      useNayaxReconciliation.ts          [new]
      useMachines.ts                     [add updateNayaxMachineId helper]
    pages/
      reports/
        nayax-reconciliation.vue         [new]
      machines/
        [id].vue                         [add nayax_machine_id field to edit modal]
    components/
      nayax/
        UploadStep.vue                   [new]
        MappingStep.vue                  [new]
        SettingsStep.vue                 [new]
        ResultsView.vue                  [new]
        MatchedTable.vue                 [new]
        MissingInDbTable.vue             [new]
        GhostInDbTable.vue               [new]
    i18n/
      locales/
        de.json                          [+ nayax.* keys]
        en.json                          [+ nayax.* keys]

Docker/supabase/migrations/
  YYYYMMDDHHMMSS_vending_machine_nayax_id.sql   [new]
```

The five Nayax components are split out (rather than crammed into one giant `nayax-reconciliation.vue`) so each has one job. Each component receives reactive props and emits intent events to the page; none of them owns the workflow state — that lives in `useNayaxReconciliation`.

### `useNayaxReconciliation.ts` — the workflow brain

Public surface:

```ts
export interface NayaxRow {
  rowIndex: number               // 1-based in the source file, for error messages
  txId: string
  nayaxMachineId: string         // raw value from column 15
  machineName: string
  productGroup: string
  productName: string
  paymentSource: string          // "Cash" | "Credit Card(CLS)" | ...
  priceGross: number             // rounded to 2dp
  itemNumber: number | null      // parsed from column 14, null if regex fails
  selectionInfoRaw: string       // column 14 raw, kept for display
  localDt: string                // "DD.MM.YYYY HH:MM:SS" exactly as in file
  utcDt: string                  // ISO 8601 UTC after timezone conversion
}

export interface DbSale {
  id: string
  created_at: string             // UTC from DB
  machine_id: string
  item_number: number | null
  item_price: number | null
  channel: string | null
  product_id: string | null
  product_name: string | null    // joined via product_id
}

export interface MatchPair {
  nayax: NayaxRow
  db: DbSale
  deltaSeconds: number           // db.created_at - nayax.utcDt
}

export interface ReconResult {
  matched: MatchPair[]
  missingInDb: NayaxRow[]        // in Nayax, not in our DB
  ghostInDb: DbSale[]            // in our DB, not in Nayax
  unmapped: NayaxRow[]           // Nayax machine ID has no DB mapping
  unparseable: NayaxRow[]        // could not extract item_number
  fileDateRange: { fromUtc: string; toUtc: string } | null
  settings: {
    timezone: string
    toleranceSeconds: number
  }
}

export function useNayaxReconciliation() {
  // state
  const file: Ref<File | null>
  const rawRows: Ref<NayaxRow[]>
  const dbSales: Ref<DbSale[]>
  const mapping: Ref<Map<string, string>>  // nayaxMachineId → vendingMachine.id
  const settings: Ref<{ timezone: string; toleranceSeconds: number; fromUtc: string; toUtc: string }>
  const result: Ref<ReconResult | null>
  const step: Ref<'upload' | 'mapping' | 'settings' | 'results'>
  const parsing, matching, importing, deleting: Ref<boolean>
  const error: Ref<string>

  // actions
  async function parseFile(f: File): Promise<void>
  async function loadMappingForCompany(): Promise<void>
  function detectUnmappedIds(): string[]
  async function saveMapping(nayaxId: string, vmId: string | null): Promise<void>
  async function loadDbSales(): Promise<void>
  function runMatch(): void
  async function bulkImportMissing(rows: NayaxRow[]): Promise<{ imported: number; errors: string[] }>
  async function deleteGhost(saleId: string): Promise<void>
  function exportDiffCsv(): string
  // CSV layout (one row per Nayax row + ghosts):
  //   bucket            ("matched" | "missing_in_db" | "ghost_in_db" | "unmapped" | "unparseable")
  //   nayax_time_local  ("DD.MM.YYYY HH:MM:SS")
  //   nayax_time_utc    (ISO 8601)
  //   db_time_utc       (ISO 8601, blank if no DB side)
  //   delta_seconds     (blank unless matched)
  //   machine_name      (DB side if available, else Nayax side)
  //   slot              (item_number)
  //   product           (DB side if available, else Nayax productName)
  //   price             (gross, 2dp)
  //   payment_source    (Nayax raw)
  //   channel           (DB channel if available)
  //   nayax_tx_id
  //   db_sale_id        (blank if no DB side)
  function reset(): void

  // settings persistence
  function loadStoredSettings(): void  // localStorage on init
  function persistSettings(): void
}
```

### Page flow `/reports/nayax-reconciliation`

Step machine driven by `useNayaxReconciliation.step`:

1. **Upload** — drag/drop or file picker. On file selection: `parseFile` populates `rawRows` + initial `settings` (date range from row 1, tz default `Europe/Berlin`, tolerance default 10 s from `localStorage`). On success: `loadMappingForCompany`, then check `detectUnmappedIds`. If unmapped: go to step 2. Otherwise → step 3.

2. **Mapping** — only shown when ≥1 Nayax machine ID in the file has no DB mapping. Table:

   | Nayax ID | Nayax Machinename | Maps to                  |
   |----------|-------------------|--------------------------|
   | 92700604 | Niedernhall Fr…   | [Combobox: our machines] |
   | 824257353| Giebelheide Z…    | [Combobox: our machines] |

   Each picker is a search-as-you-type combobox (reuse the existing `components/ProductCombobox.vue` pattern, renamed/abstracted as needed) — plain `<select>` is painful at 50+ machines. Combobox shows `vendingMachine.name`. A separate "Skip — don't analyze this machine for this upload" option leaves the mapping null and excludes those rows **from this run only** — the row reappears in the mapping step on the next upload, so skip is *not* a "don't ask again" flag. Save button writes the picked mappings via `updateNayaxMachineId(vmId, nayaxId)` then advances to step 3.

3. **Settings** — three controls:
   - **Zeitraum** — date+time inputs, pre-filled from the file's row 1. Used to scope the DB sales query.
   - **Zeitzone der Nayax-Datei** — dropdown of common TZs, default `Europe/Berlin`, persisted to `localStorage` as `nayax-reconcile-tz`.
   - **Zeit-Toleranz** — numeric input in seconds, default **10**, range 5–600. Persisted as `nayax-reconcile-tolerance`.

   Submit triggers `loadDbSales()` + `runMatch()` → step 4.

4. **Results** — full page width:
   - **Header bar**: stats (matched / missing / ghosts / nayaxTotal), settings recap (range + tz + tolerance), buttons (Re-run with different settings · Export diff CSV · Start over).
   - **Sections** (collapsible cards, count badge in each header):
     - ✓ **Übereinstimmend** — collapsed by default. When opened: table sorted by time, columns `Time (local) · Machine · Slot · Product · Price · Δ time` (Δ formatted as `+2 s` / `-1 s`).
     - ⚠ **Fehlt in Datenbank** — expanded by default. Columns `[✓] · Time (local) · Machine · Slot · Product · Price · Payment · Nayax-Tx-ID`. Bulk action bar appears above when ≥1 checked: `[Selected: N]  [Import as manual sales]`. Bulk button opens confirmation modal showing the count and the resulting `channel` distribution before running.
     - ⓘ **Nur in Datenbank** — expanded by default. Columns `Time (local) · Machine · Slot · Product · Price · Channel · [Delete]`. Per-row delete button opens confirmation modal mentioning the stock-restoration side effect.
     - Optional section **„Ungemappt / Nicht parsbar"** — only rendered when `unmapped.length + unparseable.length > 0`. Lists each row with reason. "Mapping erweitern" button jumps back to step 2.

### Match algorithm

```
toleranceMs = settings.toleranceSeconds * 1000

mappedRows  = rawRows.filter(r => mapping.has(r.nayaxMachineId) && r.itemNumber != null)
unmapped    = rawRows.filter(r => !mapping.has(r.nayaxMachineId))
unparseable = rawRows.filter(r => mapping.has(r.nayaxMachineId) && r.itemNumber == null)

usedDbSaleIds = new Set<string>()
matched = []
missingInDb = []

for n in mappedRows sorted by utcDt ascending:
  vmId = mapping.get(n.nayaxMachineId)
  candidates = dbSales.filter(s =>
    s.machine_id === vmId
    && s.item_number === n.itemNumber
    && roundTo2dp(s.item_price) === roundTo2dp(n.priceGross)
    && Math.abs(parseISO(s.created_at).getTime() - parseISO(n.utcDt).getTime()) <= toleranceMs
    && !usedDbSaleIds.has(s.id)
  )
  if candidates.length === 0:
    missingInDb.push(n)
  else:
    best = candidates.reduce((a, b) =>
      Math.abs(parseISO(a.created_at).getTime() - parseISO(n.utcDt).getTime())
        <= Math.abs(parseISO(b.created_at).getTime() - parseISO(n.utcDt).getTime())
        ? a : b
    )
    matched.push({ nayax: n, db: best, deltaSeconds: (parseISO(best.created_at).getTime() - parseISO(n.utcDt).getTime()) / 1000 })
    usedDbSaleIds.add(best.id)

mappedVmIds = new Set(mapping.values())
ghostInDb = dbSales.filter(s =>
  s.machine_id !== null
  && mappedVmIds.has(s.machine_id)
  && !usedDbSaleIds.has(s.id)
  && parseISO(s.created_at) within [fromUtc, toUtc]
)
```

Match is greedy + one-to-one: each DB sale matches at most one Nayax row. Greedy is fine because the realistic case is "1–3 sales drift per month" — no pathological ambiguity expected. Sort by Nayax time first so earlier rows get first pick on close candidates. **Note for implementation**: under a future workload with many near-simultaneous sales on the same slot (e.g. coffee machine at lunch rush), greedy can mis-assign by 1–2 seconds. If that becomes a real problem we can swap to Hungarian / minimum-cost matching — for v1 leave a code comment, don't pre-build it.

### Importing missing sales

Bulk action calls `insert_manual_sale` once per selected row. The RPC signature (from `20260412000000_sales_product_id_snapshot.sql`):

```
insert_manual_sale(p_machine_id uuid, p_item_number int, p_item_price float8,
                  p_channel text, p_created_at timestamptz DEFAULT now())
```

Channel derivation from `Payment Method (Source)`:

| Nayax `paymentSource`         | Resulting `sales.channel` |
|-------------------------------|---------------------------|
| `Cash`                        | `cash`                    |
| `Credit Card(CLS)` (and `Credit Card(*)`) | `card`        |
| anything else                 | `nayax`                   |

`p_created_at` is the Nayax `utcDt` (already converted). The RPC's existing trigger `stamp_machine_and_decrement_stock` will fire and decrement tray stock — **this is the desired behavior**, since these are real sales we forgot to record, and they should affect stock just like any real sale would have.

Errors per row are collected and shown in the result modal. The successful rows are removed from `missingInDb` and the local `dbSales` is refetched so a subsequent re-run reflects the new state.

### Deleting ghost sales

Per-row only (no bulk in v1 — deletion is destructive). Uses the existing RPC:

```
delete_sale_and_restore_stock(sale_id uuid)
```

The RPC restores tray stock (existing behavior). After success the row is removed from `ghostInDb`.

## Edge cases and decisions

| Case | Decision |
|------|----------|
| Multiple DB candidates within tolerance | Pick the one with the smallest absolute Δ. If two are equidistant, pick the earlier one (deterministic). |
| Nayax `Produktauswahl-Informationen` has no `(N  price)` group | Bucket `unparseable`. Show the raw text so the user can spot a Nayax-side config issue. |
| `sales.machine_id IS NULL` (very old sales) | Excluded from both `matched` and `ghostInDb`. We can't reason about them. |
| `sales.item_number IS NULL` | Excluded from matching (will surface as ghost only if it overlaps the date range and machine is mapped). |
| Nayax row's `Maschinen-ID` is empty | Treated as unmapped (joined as `""` key). |
| File timezone changes between uploads | Stored in `localStorage` per browser, not per company — survives session, doesn't leak across users. |
| Refund / negative-price rows | Out of scope for v1. If a row has `priceGross <= 0`, it goes into `unparseable` with reason "negative or zero amount". |
| Very large files | Soft warning at `rawRows.length > 10 000` recommending a narrower date range. Hard refusal at `rawRows.length > 50 000` with an explicit error ("File too large — split by month") to bound worst-case browser memory. Match is O(n·m) but the inner filter is constant-time on small candidate sets, so the soft threshold is conservative. |
| Mapping a Nayax ID to "skip" | Persisted as no change to the DB (mapping stays null). Skip is a per-run choice. |
| User uploads the wrong file (e.g. product import instead of sales) | Parser detects: missing required headers (`Transaktions-ID`, `Maschinen-Begleichszeit`, `Maschinen-ID`) → error toast, stay on step 1. |

## i18n keys

Under `nayax.*` namespace in both `de.json` and `en.json`:

- `nayax.reconcile.title`, `nayax.reconcile.upload.title/cta/dropHint`
- `nayax.reconcile.mapping.title/instruction/skipOption`
- `nayax.reconcile.settings.title/timezone/tolerance/dateRange/run`
- `nayax.reconcile.results.matched/missing/ghost/unmapped/unparseable`
- `nayax.reconcile.results.importBulkCta/importConfirmTitle/importConfirmBody`
- `nayax.reconcile.results.deleteGhostCta/deleteConfirmTitle/deleteConfirmBody`
- `nayax.reconcile.results.exportCsv/startOver/rerun`
- Error keys for parse failures, mapping save failures, RPC failures.

## Permissions

- The page is at `/reports/nayax-reconciliation` and lives under the existing `auth` middleware. All org members with reports access can view.
- **Mapping save** (writes `vendingMachine.nayax_machine_id`): same policy as existing machine-edit flows — admins only. Client-side check on `role.value === 'admin'`; UI hides the dropdown for non-admins (read-only, shows "(no mapping — ask admin)").
- **Bulk import missing**: admins only (writes via `insert_manual_sale` — the RPC enforces server-side via existing `sales` RLS, but we also hide the action in UI for viewers).
- **Delete ghost**: admins only (same reasoning).

## Testing

### Vitest (frontend)

- `useNayaxReconciliation.test.ts`:
  - `parseFile` — feed a fixture xlsx (a stripped copy of the user's sample committed to `test-helpers/fixtures/nayax-sample.xlsx`); assert it skips row 1 + 2 + last `Total` row, extracts all columns correctly, parses item_number from `Produktauswahl-Informationen`, handles missing parenthesis group.
  - `runMatch` — synthetic Nayax + DB datasets covering:
    - exact-time match
    - within-tolerance match (Δ = 9 s with tolerance 10 → matched)
    - just-outside tolerance (Δ = 11 s with tolerance 10 → missing)
    - price mismatch by 0.001 (gets rounded → still matches)
    - price mismatch by 0.01 (genuine mismatch → not matched)
    - two Nayax rows compete for one DB sale → earlier Nayax row wins, later becomes missing
    - one Nayax row, two DB candidates within tolerance → closer wins
    - DB sale within date range but no Nayax match → ghost
    - mapping skipped → row is in `unmapped`, not in `missingInDb`
  - Timezone tests:
    - `2026-03-31 21:46:09` Europe/Berlin → `2026-03-31T19:46:09.000Z` (CEST)
    - `2026-01-15 12:00:00` Europe/Berlin → `2026-01-15T11:00:00.000Z` (CET)
    - DST transition day — spring-forward gap. The local instant `2026-03-29 02:30:00` does not exist in Europe/Berlin (clocks jump 02:00 → 03:00). `date-fns-tz` resolves this to `2026-03-29T01:30:00.000Z` (i.e. it interprets the input as the *post-jump* 03:30 CEST). Test asserts exactly this so a future reader doesn't think the result is wrong.

### Manual smoke test plan

1. Apply migration → confirm `vendingMachine.nayax_machine_id` column exists.
2. In `/machines/[id]`, set `nayax_machine_id = 92700604` for one of the user's actual machines. Save. Reload — value persists.
3. Open `/reports/nayax-reconciliation`. Upload the user's `tmp/nayax-sale.xlsx`.
4. Confirm the mapping step lists only the *unmapped* Nayax IDs (i.e. only `824257353`, since `92700604` is already mapped from step 2). Map it.
5. Confirm settings step pre-fills the March 2026 date range and `Europe/Berlin`. Click run.
6. Confirm results page renders four sections with sensible counts.
7. Pick one row in "Fehlt in Datenbank", import. Verify a `sales` row appears in `/machines/[id]` history with `channel = cash` and the same UTC timestamp.
8. If any ghost exists, delete one. Verify it disappears from the section and the tray stock incremented.

## Dependencies added

- `date-fns-tz` (≈ 10 KB gzipped, MIT licensed) — for parsing `DD.MM.YYYY HH:MM:SS` in Europe/Berlin → UTC with correct DST handling. The project already uses native `Date` everywhere; we add this one small lib because hand-rolling DST is a known bug magnet. Alternative considered: `Intl.DateTimeFormat` round-trip — works but uglier and slower for batch parsing.

No new server-side dependencies.

## Backward compatibility

- **Firmware**: untouched. Firmware never reads `vendingMachine.nayax_machine_id`.
- **Mobile clients (iOS / Android native)**: untouched. They `select('*')` on machines and silently ignore the new column.
- **MQTT contract**: untouched.
- **Existing sales pipeline**: untouched — `insert_manual_sale` and `delete_sale_and_restore_stock` are reused with their existing signatures.
- **Migration is additive** (nullable column + partial index) — safe on prod, no downtime, immediately rollback-able by `ALTER TABLE … DROP COLUMN`.

## Open questions / explicit deferrals

These were considered and deliberately pushed out of v1:

1. **Persistent reconciliation history** — would let users see "we ran an analysis on April's data on May 5 and there were 3 misses". v1 is purely ephemeral. Add a `nayax_reconciliations` table later if needed.
2. **Refund handling** — Nayax can export refund/cancellation rows. We don't have a refund concept in `sales` yet, so v1 just buckets them as `unparseable`. Proper refund support requires `sales`-table semantics design.
3. **Bulk-delete ghosts** — explicitly omitted because delete is destructive and we'd rather force the user to confirm each one.
4. **Cross-month / cumulative drift dashboard** — out of scope; this is a one-shot analyzer.
5. **Sync direction reversed (find sales we have that Nayax missed)** — that's exactly what "Nur in Datenbank" already shows. Naming is intentional: "ghost" carries the right connotation for both possibilities (ours is fake, or Nayax missed it).

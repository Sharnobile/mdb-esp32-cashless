# Nayax reconciliation: order-based (sequence) matching

**Date:** 2026-06-01
**Area:** `management-frontend` → `/reports/nayax-reconciliation`
**Type:** Behavior change to an existing feature (matching algorithm + results presentation)

## Problem

The Nayax reconciliation matcher pairs each Nayax row to a DB sale by
`machine + slot + price` **within a ±N-second time window** (`toleranceSeconds`,
default 10 s). When the machine clock and the MQTT/DB timestamps drift apart —
which happens "here and there" in the field — the window misfires:

- a real, present sale falls outside the window → wrongly reported **missing in DB**,
- and its DB twin is left unconsumed → wrongly reported as a **ghost (DB-only)**.

So a single drifted sale produces *two* false findings at once. The operator
can't trust either bucket, which defeats the tool's purpose: filling genuine
gaps in the local DB.

## Goal

Stop trusting the seconds. Model the reality the operator describes:

- **Nayax is the complete, source-of-truth list.** Everything that happened is in it.
- **The local DB is the same list with gaps** (missed MQTT messages) and,
  occasionally, **phantoms** (sales the DB counted that never happened —
  double-counts, aborted vends).

Therefore: per machine, compare the two as **ordered sequences of products** and
report, in both directions, what doesn't line up:

| Direction | Meaning | Operator action |
|-----------|---------|-----------------|
| In Nayax, not in DB | a real sale the DB missed | **add** (bulk import — unchanged) |
| In DB, not in Nayax | a phantom / double-count | **review & remove** (per-row delete — unchanged) |

Time is used **only to sort** each sequence — never to decide a match. A constant
clock offset or a few seconds of drift no longer changes any result.

## Approach: per-machine sequence diff (LCS), keyed on slot

Chosen over (B) a greedy two-pointer heuristic — rejected because a heuristic that
can invent false gaps is unacceptable in a tool that *creates sales records* — and
over (C) widening the time tolerance — rejected because it papers over the very
problem we're removing.

### Matching key (decided)

Two sales align when they share the **same slot / `item_number`**, in sequence
order. **Price is not part of the key.** When an aligned pair has differing prices,
it still counts as matched but is **flagged** (`priceDiffers`) so a re-priced or
mis-recorded product is visible without creating a false gap.

### Algorithm (`useNayaxReconciliation.ts → runMatch`)

The pre-filter is **unchanged**:
- Nayax row on an unmapped machine → `unmapped`.
- Nayax row with `itemNumber == null` or `priceGross <= 0` → `unparseable`.

Everything else is **grouped by mapped VM id** and aligned independently:

1. **A** = that machine's eligible Nayax rows, sorted by `utcDt` ascending.
2. **B** = that machine's DB sales, sorted by `created_at` ascending.
3. Compute **LCS(A, B)** with equality predicate `a.itemNumber === b.item_number`.
   Recover the alignment:
   - aligned pairs → `matched`. Each carries `deltaSeconds`
     (`db.created_at − nayax.utcDt`, now **informational only**) and
     `priceDiffers = roundTo2(nayax.priceGross) !== roundTo2(db.item_price)`.
   - A-only items → `missingInDb` (the importable gaps).
   - B-only items, **strictly within `[fromUtc, toUtc]`** → `ghostInDb` (phantoms).
     (B items only in the boundary buffer — see below — are dropped, never ghosts.)
4. Concatenate all machines' results into the existing `ReconResult` shape.

Repeated products (same slot vended several times) are handled naturally by the
sequence diff. Two machines never cross-align (grouping is per VM).

**Complexity & guard.** LCS is `O(n·m)` time / `O(n·m)` space per machine. For a
realistic monthly–quarterly export (a busy machine ≈ 1,500 sales/mo → ~2.25M cells,
`Int32Array`, < 100 ms) this is trivial. A per-machine guard caps the DP at a cell
budget (≈ 25M cells); if a single machine's `n·m` exceeds it, that machine falls
back to **day-bucketed LCS** (align within each file-timezone calendar day, then
concatenate) and a non-blocking notice is surfaced. This keeps the tab from ever
hanging on a pathological single-machine, year-long upload, at the cost of possibly
splitting a sale that drifted across midnight on that machine only. No silent
truncation — if the fallback engages, the operator is told.

### Boundary robustness

`loadDbSales` widens its query window by a small fixed **±2-minute buffer** around
`[fromUtc, toUtc]`. A sale that drifted just across the file's start/end can then
still find its twin and align (no false gap at the edges). The ghost filter stays
**strict** to the real `[fromUtc, toUtc]`, so a buffer-only DB row can partner a
match but can never itself be flagged as a phantom.

## Data model changes (`useNayaxReconciliation.ts`)

- `MatchPair` gains `priceDiffers: boolean`. `deltaSeconds` is retained (now
  informational; still used by CSV export and the matched table).
- `settings` loses `toleranceSeconds`. Shape becomes
  `{ timezone, fromUtc, toUtc }`.
- `ReconResult.settings` loses `toleranceSeconds`. (The buckets `matched`,
  `missingInDb`, `ghostInDb`, `unmapped`, `unparseable` and `fileDateRange` are
  unchanged.)
- `bulkImportMissing`, `deleteGhost`, `logNayaxActivity`, `exportDiffCsv`, `reset`,
  mapping helpers, and the parser are **unchanged in behavior**. (`exportDiffCsv`
  keeps its `delta_seconds` column.)

## UI changes

### Settings step (`NayaxSettingsStep.vue`, `pages/reports/nayax-reconciliation.vue`)

- **Remove the "Time tolerance (seconds)" number field** and its hint.
- Remove the `nayax-reconcile-tolerance` localStorage read/write and the
  `Math.max(5, Math.min(600, …))` tolerance clamp in both the component's `submit()`
  and the page's `onMounted`. From / To / Timezone (and the `nayax-reconcile-tz`
  localStorage) stay.

### Results header (`NayaxResultsView.vue`)

- Replace the `· ±{toleranceSeconds}s` suffix with a label describing the method
  (`results.matchMethod`, e.g. EN "matched by product order" / DE "Abgleich nach
  Produkt-Reihenfolge").
- If any matched pair has `priceDiffers`, append a small count
  (`results.priceDiffersN`, e.g. "3 price differences").

### Differences table (`NayaxDifferencesTable.vue`) — phantom highlighting

The merged chronological table and the bulk-**import** flow for missing rows stay.
Phantom (DB-only) rows are **promoted from the current soft "info" look to a warning
treatment**:

- swap `IconInfoCircle` + yellow for `IconAlertTriangle` + amber/red emphasis on the
  badge and (subtly) the row,
- relabel the badge from "DB only" to something that states the consequence, e.g.
  EN "DB only — likely false sale" / DE "nur in DB — vermutlich Fehlverkauf"
  (`results.bucketGhostWarn`),
- add a one-line explanation above/within the section
  (`results.ghostExplain`, e.g. DE "Diese Verkäufe stehen in der DB, aber nicht in
  Nayax — vermutlich fälschlich gezählte Doppelverkäufe.").
- **Removal stays per-row** (existing `IconTrash` + `deleteConfirmBody` confirm). No
  bulk-delete surface is added (decided: safer/more deliberate for record deletion).

### Matched table (`NayaxMatchedTable.vue`)

- Add a small "price differs" badge (`results.priceDiffers`) on rows where
  `priceDiffers === true`.

## i18n (`i18n/locales/{en,de}.json`)

- **Remove** `nayax.reconcile.settings.tolerance` and `…settings.toleranceHint`.
- **Add** under `nayax.reconcile.results`: `matchMethod`, `priceDiffers`,
  `priceDiffersN`, `bucketGhostWarn`, `ghostExplain`.
- German strings use the informal *du* form, consistent with the existing file.

## Out of scope (YAGNI)

- No toggle to keep the old timestamp matcher — it's being replaced outright.
- No bulk-delete for phantoms (per-row only, decided).
- No Myers/Hirschberg implementation unless the per-machine guard ever trips in
  practice; day-bucketed LCS is the bounded fallback.
- No change to import / delete RPCs, activity logging, CSV mechanics, mapping step,
  or the parser.

## Testing (`__tests__/useNayaxReconciliation.test.ts`)

`localDtToUtc`, `parseSelectionInfo`, `parseTitleDateRange`, `parseFile`,
`derivedChannelFromPaymentSource`, and `exportDiffCsv` tests are **untouched**
(except `setupRecon`/`exportDiffCsv` no longer pass `toleranceSeconds`).

The `runMatch` describe block is **rewritten** for sequence semantics. New/updated
cases:

1. **DB is an exact in-order subset** → all matched, correct `missingInDb`, zero ghosts.
2. **Gap in the middle** → exactly that Nayax row is `missingInDb`; the rest match.
3. **Clock drift, same order** (the key regression): Nayax and DB timestamps differ
   far beyond any old tolerance, but the product order is identical → **all matched,
   zero missing, zero ghosts**. (Under the old matcher these would all be
   missing+ghost.)
4. **Phantom** → a DB sale with no Nayax counterpart, in range → `ghostInDb`.
5. **Repeated slot** (same product vended twice) → both align correctly; one missing
   when the DB only has one of them.
6. **Price differs, slot matches** → `matched` with `priceDiffers === true`.
7. **Adjacent order swap** → documents the accepted behavior (1 missing + 1 ghost).
8. **Per-machine independence** → identical slot sequences on two different VMs do
   not cross-align.
9. **Boundary buffer** → a DB sale just outside `[fromUtc,toUtc]` but within the
   buffer aligns with its in-range Nayax twin (no false missing) and is **not** a ghost.
10. `unmapped` / `unparseable` pre-filter behavior unchanged.

## Files touched

| File | Change |
|------|--------|
| `app/composables/useNayaxReconciliation.ts` | rewrite `runMatch` (LCS); `MatchPair.priceDiffers`; drop `toleranceSeconds` from `settings` + `ReconResult`; ±2 min buffer in `loadDbSales` |
| `app/components/nayax/NayaxSettingsStep.vue` | remove tolerance field/clamp |
| `app/pages/reports/nayax-reconciliation.vue` | remove tolerance localStorage + clamp |
| `app/components/nayax/NayaxResultsView.vue` | header method label + price-diff count |
| `app/components/nayax/NayaxDifferencesTable.vue` | phantom warning styling + explanation |
| `app/components/nayax/NayaxMatchedTable.vue` | price-differs badge |
| `i18n/locales/en.json`, `i18n/locales/de.json` | remove tolerance keys; add new result keys |
| `app/composables/__tests__/useNayaxReconciliation.test.ts` | rewrite `runMatch` tests |

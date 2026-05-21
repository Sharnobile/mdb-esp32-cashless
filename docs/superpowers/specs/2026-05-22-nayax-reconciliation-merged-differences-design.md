# Nayax Reconciliation — Merged Chronological Differences View

**Date:** 2026-05-22
**Author:** Lucien Kerl (with Claude)
**Status:** Draft → User review pending
**Builds on:** [2026-05-20 Nayax Sales Reconciliation](2026-05-20-nayax-sales-reconciliation-design.md) (already shipped)

## Goal

Refactor the Results step of `/reports/nayax-reconciliation` so the two diff buckets — "Fehlt in Datenbank" and "Nur in Datenbank" — are merged into a single chronologically-sorted table. With the current split layout, the user can't see two related events next to each other (e.g. a Nayax sale at 14:32 and a near-miss DB sale at 14:34) when triaging *why* a particular product reconciled poorly.

Secondary goal: unify the date format across all result tables. Today the Missing table renders the raw Nayax string (`DD.MM.YYYY HH:MM:SS`) and the Ghost table renders `new Date(iso).toLocaleString()` — both inconsistent with each other and with the rest of the app, which uses `formatDateTime()` from `lib/utils.ts`.

## Non-goals

- No matcher / algorithm changes — bucketing remains correct, just rendered differently.
- No DB or composable API changes — `bulkImportMissing` / `deleteGhost` keep their signatures.
- Matched section stays separate (and stays collapsed by default). The user explicitly asked about merging the two diff buckets, not all three.
- No bulk delete for ghosts — destructive action remains per-row.

## Current state (what we're replacing)

Three components rendered as three independent cards in `NayaxResultsView.vue`:

```
┌─ ⚠ Fehlt in Datenbank (3) ───────────────────────────┐
│  Time(Nayax local)  Machine  Slot  Product  Price …  │
│  [✓] checkboxes for bulk import                       │
└──────────────────────────────────────────────────────┘
┌─ ⓘ Nur in Datenbank (1) ────────────────────────────┐
│  Time(browser locale)  Slot  Product  Price  Channel │
│  [Delete] per row                                     │
└──────────────────────────────────────────────────────┘
┌─ ✓ Übereinstimmend (123) ───────────────────────────┐
│  collapsed by default                                 │
└──────────────────────────────────────────────────────┘
```

Date format mismatch and the lack of chronological correlation make root-cause triage painful.

## Target state

```
┌─ Abweichungen (4) ──────────────────────────────────────────────────────────────┐
│  [✓]  Zeit             Typ          Maschine   Slot  Produkt    Preis  Zahlung  │
│  [✓]  14:32:09 22.05.  ⚠ fehlt DB   Frankenec  58    Powerade   2,50 € Cash     │
│   ─    14:34:11 22.05.  ⓘ nur DB     Frankenec  58    Powerade   2,50 € cash     │
│  [✓]  15:01:40 22.05.  ⚠ fehlt DB   Zenkert    39    Mars       1,20 € Card     │
│   ─    16:22:00 22.05.  ⓘ nur DB     Zenkert    12    Snickers   1,50 € cash     │
│                                                                                  │
│  Bulk: [2 ausgewählt]  [Als manuelle Verkäufe importieren]                       │
└──────────────────────────────────────────────────────────────────────────────────┘
┌─ ✓ Übereinstimmend (123) — collapsed                                            │
└──────────────────────────────────────────────────────────────────────────────────┘
```

Two rows that nearly-matched (just outside tolerance) now sit next to each other so the user can immediately see: same machine, same slot, same product, same price, but 2 seconds outside the tolerance window — answer obvious in one glance.

## Sort key

All four bucket types (missing, ghost, also matched if reused later) share a unifying property: a UTC ISO timestamp.

- Missing rows: `NayaxRow.utcDt` (already ISO 8601 with `Z` suffix from `localDtToUtc`).
- Ghost rows: `DbSale.created_at` (already UTC from Postgres `timestamptz`).

Both ISO-8601-with-Z strings sort chronologically under plain lexicographic string comparison. No `Date.parse` needed at render time — a single sort over a flat tagged array (see rendering details below) produces the right order.

**Verified assumption**: `DbSale.created_at` is hydrated by `loadDbSales` from PostgREST, which serializes Postgres `timestamptz` as ISO-8601 with a `Z` suffix. `NayaxRow.utcDt` is produced by `localDtToUtc()` which always ends in `Z` (or an empty string if the date was malformed — but unparseable rows are routed to the `unparseable` bucket before reaching the matcher, so they never appear in `missing` or `ghosts`).

## Date format

Single source of truth: `formatDateTime(iso, locale)` from `app/lib/utils.ts`. The helper uses `Intl.DateTimeFormat` and is already used in `/reports/index.vue` and elsewhere.

For Missing rows, feed `utcDt` (UTC ISO) → browser renders in browser-local time, German format (`22.05.2026, 14:32:09`). For Ghost rows, feed `created_at` (UTC ISO) → same path. Both render identically.

Note: this means Missing rows no longer display their original `localDt` string verbatim. That's intentional — the user's mental model is "when did this happen on the machine?", and as long as the timezone is consistent across the view, the absolute instant is what matters. The raw Nayax string is still available in the CSV export.

The Matched table currently renders `m.nayax.localDt` as a raw string; this refactor also routes it through `formatDateTime(m.nayax.utcDt, locale)` for consistency across all result tables.

## Components and data flow

### File structure

```
management-frontend/app/components/nayax/
  NayaxResultsView.vue          [modify] — renders 1 diff section + matched, not 2 diff sections
  NayaxDifferencesTable.vue     [new]    — replaces both Missing and Ghost components
  NayaxMissingInDbTable.vue     [delete]
  NayaxGhostInDbTable.vue       [delete]
  NayaxMatchedTable.vue         [modify] — switch raw localDt to formatDateTime(utcDt, locale)
  NayaxUnmappedSection.vue      [no change]
  NayaxUploadStep.vue           [no change]
  NayaxMappingStep.vue          [no change]
  NayaxMachineCombobox.vue      [no change]
  NayaxSettingsStep.vue         [no change]
```

### `NayaxDifferencesTable.vue` (new) — interface

Props:
- `missing: NayaxRow[]` — from `result.missingInDb`
- `ghosts: DbSale[]` — from `result.ghostInDb`
- `machineNameByVmId: Map<string, string>` — pre-computed reverse-lookup (vmId → machineName, derived from any Nayax row that referenced that VM). For ghosts on machines that the *current* Nayax file didn't touch, falls back to `'—'`.
- `isAdmin: boolean`
- `open: boolean`

Note: `mapping` itself is NOT passed in as a prop — the component only needs the resolved machine-name lookup, which the parent (`NayaxResultsView.vue`) computes once from `recon.rawRows.value`.

Emits:
- `toggle` — open/close the section
- (no other emits — bulk import + per-row delete call composable directly via `useNayaxReconciliation()`)

Internal state:
- `selected: Ref<Set<string>>` — Nayax `txId`s of rows the user wants to bulk-import (only Missing rows are selectable).
- `showConfirm: Ref<boolean>` — bulk-import confirm modal.
- `pendingDelete: Ref<DbSale | null>` — per-row delete confirm modal.
- `lastImportResult: Ref<{ imported, errors } | null>` — banner under the action bar.

Rendering:
1. Build a single flat array:
   ```ts
   const rows = [
     ...missing.map(m => ({ kind: 'missing' as const, ts: m.utcDt, payload: m })),
     ...ghosts.map(g => ({ kind: 'ghost' as const, ts: g.created_at, payload: g })),
   ]
   ```
2. Sort ascending by `ts` with deterministic tiebreaker (`missing` before `ghost` at identical timestamps):
   ```ts
   rows.sort((a, b) =>
     a.ts.localeCompare(b.ts) || (a.kind === 'missing' ? -1 : 1)
   )
   ```
3. Render one `<tr>` per entry. Use a `<template v-if="kind === 'missing'">` / `v-else` switch to fill columns from the right payload type.

Section header shows total count `missing.length + ghosts.length`. Card border tinted neutral (no red/yellow on the wrapper); the per-row badges carry the color cue.

### Updated `NayaxResultsView.vue`

```html
<!-- Header bar (counts, settings recap, buttons) unchanged -->

<!-- Diff section -->
<NayaxDifferencesTable
  :missing="result.missingInDb"
  :ghosts="result.ghostInDb"
  :nayax-rows-by-vm-id="machineNameByVmId"
  :is-admin="isAdmin"
  :open="diffOpen"
  @toggle="diffOpen = !diffOpen"
/>

<!-- Matched (collapsed by default) -->
<NayaxMatchedTable ... />

<!-- Unmapped / unparseable -->
<NayaxUnmappedSection ... />
```

The `machineNameByVmId` lookup is computed in `NayaxResultsView.vue` from `recon.rawRows.value` (walk once, build a `Map`) and passed down. Reusing the existing `exportDiffCsv` logic which already does this lookup.

### `NayaxMatchedTable.vue` change

One-line change: replace `{{ m.nayax.localDt }}` with `{{ formatDateTime(m.nayax.utcDt, locale) }}` and add the matching imports + `locale` from `useI18n()`.

**Sharp edge — do NOT propagate this to the composable.** `exportDiffCsv()` in `useNayaxReconciliation.ts` still emits `m.nayax.localDt` in the CSV `nayax_time_local` column. That's intentional — the CSV documents the *raw* Nayax timestamp string for the user to cross-reference with the source file. The UI display switching to `formatDateTime` is purely cosmetic; the CSV emission is unchanged.

### Row visual design

Row layout (one `<tr>`):

| Column | Missing payload | Ghost payload |
|--------|-----------------|---------------|
| Checkbox | `<input type="checkbox">` selectable | `<span class="text-muted-foreground">—</span>` placeholder |
| Time | `formatDateTime(payload.utcDt, locale)` | `formatDateTime(payload.created_at, locale)` |
| Badge | Red pill: "Fehlt in DB" / "Missing in DB" | Yellow pill: "Nur in DB" / "DB only" |
| Machine | `payload.machineName` | `machineNameByVmId.get(payload.machine_id) ?? '—'` |
| Slot | `payload.itemNumber` | `payload.item_number` |
| Product | `payload.productName` | `payload.product_name ?? '—'` |
| Price | `formatCurrency(payload.priceGross, locale)` | `formatCurrency(payload.item_price, locale)` |
| Payment | `payload.paymentSource` | `payload.channel ?? '—'` |
| ID | `payload.txId` (font-mono, small) | `payload.id.slice(0,8)` (font-mono, small) |
| Action | (none — selected via checkbox + bulk) | `<button @click="pendingDelete = payload">Löschen</button>` (admin only) |

Badge styling: `inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium` with background-tint variant per bucket. Matches the project's existing badge convention (see e.g. status badges on `/machines`).

### Bulk-import action bar

Appears when `selected.size > 0 && isAdmin`. Identical to the current pattern in `NayaxMissingInDbTable.vue`: counter + button + confirm modal (reuses `AppModal`).

### i18n

New keys under `nayax.reconcile.results.*`:

- `differencesTitle` — "Abweichungen" / "Differences"
- `bucketMissing` — "Fehlt in DB" / "Missing in DB"
- `bucketGhost` — "Nur in DB" / "DB only"

Existing keys reused:
- `colTime`, `colMachine`, `colSlot`, `colProduct`, `colPrice`, `colPayment`, `colTxId`
- `selectedN`, `importCta`, `importConfirmTitle`, `importConfirmBody`, `importedN`, `importErrors`, `showErrors`
- `deleteConfirmTitle`, `deleteConfirmBody`
- `allMatched`, `noGhosts` → fold into a single new key `noDifferences` ("Keine Abweichungen gefunden." / "No differences found.")

Header-bar count strip in `NayaxResultsView.vue` continues to use:
- `matchedShort`, `missingShort`, `ghostShort` — those references are preserved.

Existing keys becoming orphaned after the refactor:
- `missingTitle`, `ghostTitle` — were used as section headers in the two deleted components; after the merge the new section uses `differencesTitle` instead.
- `allMatched`, `noGhosts` — replaced by `noDifferences`.

These orphan keys remain in `de.json` / `en.json` for this commit (removing them is a separate i18n-cleanup concern) and they cause no runtime breakage — vue-i18n simply never resolves them. A follow-up cleanup task is captured at the bottom of this spec.

### Header-bar count strip

`NayaxResultsView.vue`'s header bar currently shows `{matched} matched · {missing} missing · {ghosts} ghosts` — keep this as-is. The merged table is for drill-down; the header strip is still the at-a-glance summary and benefits from showing the bucket split.

## Edge cases

| Case | Behavior |
|------|----------|
| `missing.length + ghosts.length === 0` | The section card is rendered unconditionally (no `v-if` gate on the parent) and shows the `(0)` count. When opened, the body shows `t('nayax.reconcile.results.noDifferences')` instead of an empty table. The user always sees a "Differences" section so the layout never surprises. |
| Ghost on a machine the current Nayax file didn't touch | `machineNameByVmId.get(machine_id)` returns `undefined` → display `—`. The CSV export already handles this case the same way. |
| Two rows with identical UTC timestamps (one missing + one ghost) | Stable secondary sort: kind=`'missing'` comes before kind=`'ghost'` so the user sees the "what Nayax recorded" entry first. Implemented via a small tiebreaker in the sort comparator. |
| Bulk import fails partway | Same as today: error list collapsible under the banner, banner switches to amber. No regression. |
| User selects rows, then re-runs (different settings) | `selected` is component-local; the section unmounts and re-mounts when results change → selection cleared. Acceptable. |
| Very long product names | Standard text wrapping in cells. Mobile gets `overflow-x-auto` wrapper around the table (same pattern as the existing tables it replaces). |

## Testing

No new Vitest cases needed — the matcher's behavior is unchanged. Manual smoke test:

1. Upload the existing Nayax sample. Run the analysis.
2. Verify the new merged section renders with both Missing and Ghost rows interleaved chronologically.
3. Verify the date format is identical for both row types and uses German formatting (`22.05.2026, 14:32:09`).
4. Verify the bucket badges (red Missing / yellow Ghost) are visually distinct.
5. Select two Missing rows, import. Banner shows "2 imported", section refreshes.
6. Delete one Ghost. Confirm modal works (Escape closes, focus trap). Row disappears.
7. CSV export still emits all three buckets correctly (the composable's `exportDiffCsv` is unchanged).
8. Empty state: upload a file where every Nayax row matches a DB sale → section renders with `noDifferences` message.

## Backward compatibility

Pure frontend refactor. No DB, no MQTT, no firmware impact. Two component files deleted + one created — clean diff.

## Open questions / explicit deferrals

- **Should the Matched table also merge into the chronological view?** No — user explicitly asked about merging Missing and Ghost. Keeping Matched separate also keeps the visual hierarchy clean: "differences I need to act on" vs. "things that worked".
- **Should we also merge the Unmapped/Unparseable section?** No — those rows have no useful timestamp on the DB side and don't benefit from chronological ordering. Stays as the meta section at the bottom.
- **Cleanup of dead i18n keys** (`missingTitle`, `ghostTitle`, etc.): defer to a follow-up. They still exist in the de.json/en.json files but won't be referenced by new templates. Leaving them is harmless and a single later commit can sweep them out alongside other i18n cleanups.

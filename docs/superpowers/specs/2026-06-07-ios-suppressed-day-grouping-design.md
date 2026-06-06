# iOS: day-grouping on the suppressed-duplicates tab

**Date:** 2026-06-07
**Area:** `ios/VMflow` (native iOS only)
**Type:** Small additive UI change — mirror the Sales tab's day grouping on the Duplicates tab

## Goal

The iOS Sales tab groups its rows by day (sticky day headers). The "Duplicates" tab (auto-removed brownout duplicates) currently renders a flat list. Make it day-grouped exactly like the Sales tab.

## Scope

iOS only (`ios/VMflow/Views/Machines/MachineDetailView.swift`). No model, ViewModel, backend, or PWA change. (The user asked specifically for iOS; the PWA suppressed card stays a flat list.)

## Existing pattern to mirror (`MachineDetailView.swift`)

- `salesTab` renders: `LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) { ForEach(groupSalesByDay(recentSales), id: \.date) { group in Section { ForEach(group.sales) { SaleRow(...) } } header: { DaySectionHeader(label: dayLabel(for: group.date), count: group.sales.count) } } }`.
- `groupSalesByDay(_ sales: [Sale]) -> [DayGroup]`: `Dictionary(grouping:)` by `calendar.startOfDay(for: sale.createdAt)`, keys sorted `>`, each day's sales sorted `createdAt >`.
- `DayGroup { date: Date; sales: [Sale] }` — Sale-specific.
- `dayLabel(for: Date) -> String` (Today / Yesterday / "EEEE, d MMMM") and `DaySectionHeader(label:count:)` are generic and reusable as-is.

## Design

1. **Add a parallel grouping** (additive; `DayGroup` is `[Sale]`-typed so it can't be reused):
   - `private struct SuppressedDayGroup { let date: Date; let rows: [SuppressedSale] }`
   - `private func groupSuppressedByDay(_ rows: [SuppressedSale]) -> [SuppressedDayGroup]` — a direct parallel of `groupSalesByDay`, grouping by `Calendar.current.startOfDay(for: row.receivedAt)`, day keys sorted `>`, rows within a day sorted `receivedAt >`.
   - **Group by `receivedAt`** — that is the timestamp each `SuppressedSaleRow` displays and the list already sorts by; mirrors how `salesTab` groups by the `createdAt` its rows show.

2. **Restructure `suppressedTab`'s populated branch** — replace the flat
   `LazyVStack(spacing: 8) { ForEach(viewModel.suppressedSales) { SuppressedSaleRow(sale:, trays:) } }`
   with the day-sectioned version:
   ```
   LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
     ForEach(groupSuppressedByDay(viewModel.suppressedSales), id: \.date) { group in
       Section {
         ForEach(group.rows) { sale in SuppressedSaleRow(sale: sale, trays: viewModel.trays) }
       } header: {
         DaySectionHeader(label: dayLabel(for: group.date), count: group.rows.count, unit: "removed")
       }
     }
   }
   ```
   Keep the existing header card ("N auto-removed" + hint) above the list, the loading `ProgressView`, and the empty state all unchanged. `SuppressedSaleRow` is unchanged. Reuse `dayLabel`.

3. **Parameterize `DaySectionHeader`'s count noun (additive).** It currently hard-codes `Text("· \(count) sales")`, which reads oddly ("· 3 sales") for *removed* duplicates. Add an optional `var unit: String = "sales"` and render `Text("· \(count) \(unit)")`. The Sales-tab call sites are unchanged (default `"sales"`); the Duplicates tab passes `unit: "removed"` → "· 3 removed". (No pluralization is added — matches the existing un-pluralized "sales".)

## Backward compatibility / risk
- Purely presentational, additive; no data/model change. Read-only surface preserved.
- `SuppressedSale.receivedAt` is non-optional (`Date`), so grouping is total (no nil bucket).

## Testing
- Manual Xcode build (no iOS test harness) — verify the Duplicates tab shows sticky day headers (Today / Yesterday / date) identical in style to the Sales tab, with rows under each day.

## Files touched
| File | Change |
|------|--------|
| `ios/VMflow/Views/Machines/MachineDetailView.swift` | `SuppressedDayGroup` + `groupSuppressedByDay`; day-sectioned `suppressedTab` reusing `dayLabel`; `DaySectionHeader` gains optional `unit` param (default "sales"; Duplicates passes "removed") |

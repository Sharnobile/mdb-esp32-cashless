# iOS Suppressed Tab — Day Grouping Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group the iOS "Duplicates" (auto-removed) tab by day with sticky day headers, exactly like the Sales tab.

**Architecture:** Add a `SuppressedDayGroup` + `groupSuppressedByDay` (parallel to the existing `groupSalesByDay`, keyed on `receivedAt`); render `suppressedTab` as day Sections reusing `dayLabel`; parameterize the shared `DaySectionHeader`'s count noun (default "sales", Duplicates passes "removed").

**Tech Stack:** SwiftUI (`ios/VMflow`).

**Spec:** `docs/superpowers/specs/2026-06-07-ios-suppressed-day-grouping-design.md`

---

## Chunk 1: Day-grouped Duplicates tab (single file)

**File:** `ios/VMflow/Views/Machines/MachineDetailView.swift` (only)

> **Commit handling:** this file is committed at HEAD. **Run `git status -s` on it first.** If clean → commit normally (scoped to this one file). If it has unexpected in-flight changes (parallel session), make the additive edits and leave them UNSTAGED for the user, reporting the diff. **Never `git add -A`.** Stay on `main`.

### Task 1: Parameterize `DaySectionHeader`'s count noun (additive — Sales tab unchanged)

- [ ] **Step 1:** In the `DaySectionHeader` struct, add an optional `unit` property and use it in the count text. Change:
```swift
struct DaySectionHeader: View {
    let label: String
    let count: Int

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.semibold))
            Text("· \(count) sales")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.bar)
    }
}
```
to:
```swift
struct DaySectionHeader: View {
    let label: String
    let count: Int
    var unit: String = "sales"

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.semibold))
            Text("· \(count) \(unit)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.bar)
    }
}
```
The existing `salesTab` call site (`DaySectionHeader(label:count:)`) is unaffected — it gets the default `"sales"`.

### Task 2: Add the suppressed-sales day grouping

- [ ] **Step 1:** Add a `SuppressedDayGroup` struct next to the existing `DayGroup` struct, and a `groupSuppressedByDay` method next to `groupSalesByDay` (both inside the `MachineDetailView` struct, mirroring the Sale versions but keyed on `receivedAt`):
```swift
private struct SuppressedDayGroup {
    let date: Date
    let rows: [SuppressedSale]
}

private func groupSuppressedByDay(_ rows: [SuppressedSale]) -> [SuppressedDayGroup] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: rows) { row in
        calendar.startOfDay(for: row.receivedAt)
    }
    return grouped.keys.sorted(by: >).map { date in
        SuppressedDayGroup(date: date, rows: grouped[date]!.sorted { $0.receivedAt > $1.receivedAt })
    }
}
```
(`DayGroup` is a `private struct` member; declare `SuppressedDayGroup` the same way/scope. `groupSalesByDay`/`dayLabel` are `private func` members — match that.)

### Task 3: Day-section the `suppressedTab` populated branch

- [ ] **Step 1:** In `suppressedTab`, replace ONLY the populated-list `LazyVStack` (the `else` branch of `if viewModel.suppressedSales.isEmpty`):
```swift
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(viewModel.suppressedSales) { sale in
                                SuppressedSaleRow(sale: sale, trays: viewModel.trays)
                            }
                        }
                    }
```
with the day-sectioned version (mirroring `salesTab`):
```swift
                    } else {
                        LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                            ForEach(groupSuppressedByDay(viewModel.suppressedSales), id: \.date) { group in
                                Section {
                                    ForEach(group.rows) { sale in
                                        SuppressedSaleRow(sale: sale, trays: viewModel.trays)
                                    }
                                } header: {
                                    DaySectionHeader(label: dayLabel(for: group.date), count: group.rows.count, unit: "removed")
                                }
                            }
                        }
                    }
```
Leave the header card ("N auto-removed" + hint), the loading `ProgressView` branch, and the empty-state branch unchanged. `SuppressedSaleRow` is unchanged.

### Task 4: Verify + commit

- [ ] **Step 1: Sanity-check the edits** — `git diff -- ios/VMflow/Views/Machines/MachineDetailView.swift` shows only: the `DaySectionHeader` `unit` addition, the `SuppressedDayGroup`/`groupSuppressedByDay` additions, and the `suppressedTab` list restructure. No other code touched.
- [ ] **Step 2: Build in Xcode** (no CLI harness) — the Duplicates tab now shows sticky day headers ("Today" / "Yesterday" / "EEEE, d MMMM" · N removed) with rows grouped under each day, matching the Sales tab. (If Xcode isn't available to the executor, note it for the user.)
- [ ] **Step 3: Commit** (per the commit-handling note above — commit if the file is clean):
```bash
git add ios/VMflow/Views/Machines/MachineDetailView.swift
git commit -m "feat(ios): day-group the auto-removed duplicates tab (like sales)"
```

---

## Done criteria
- Duplicates tab is day-grouped with sticky headers identical in style to the Sales tab; each day header reads "<day> · N removed".
- `DaySectionHeader` change is additive — the Sales tab still reads "· N sales".
- Only `MachineDetailView.swift` changed; committed (or left unstaged for the user per the commit-handling note); no unrelated files touched.
- Builds in Xcode.

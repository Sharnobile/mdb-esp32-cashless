# iOS Dashboard Chart Interactivity Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three features to the dashboard's existing 30-day Revenue bar chart: drag-to-scrub tooltip with date/revenue/sales-count, dashed orange average line with "Ø XX,XX €" label, and lighter-blue weekend bars.

**Architecture:** Pure SwiftUI Charts additions — no new files, no schema changes, no network changes. Add a `dailyAverage` computed property on the existing `DashboardViewModel`, a `isWeekend` extension on `DailySales`, and rebuild the existing `chartSection` chart block to include `RuleMark` for avg + selection, `chartXSelection(value:)` binding, and conditional bar coloring.

**Tech Stack:** SwiftUI, Swift Charts (iOS 17+ APIs: `chartXSelection`, `RuleMark.annotation(overflowResolution:)`, `Animation.smooth`), Xcode String Catalog for i18n.

**Spec:** [`docs/superpowers/specs/2026-05-01-ios-dashboard-chart-interactivity-design.md`](../specs/2026-05-01-ios-dashboard-chart-interactivity-design.md)

---

## File Inventory

| File | Action | Responsibility |
|------|--------|----------------|
| `ios/VMflow/Models/Sale.swift` | Modify (append) | Add `extension DailySales { var isWeekend: Bool }` after line 63 |
| `ios/VMflow/ViewModels/DashboardViewModel.swift` | Modify | Add `var dailyAverage: Double` computed property near other `@Published` declarations |
| `ios/VMflow/Views/Dashboard/DashboardView.swift` | Modify | Replace `chartSection` chart-block with extended version; add `@State private var selectedDate: Date?`, `selectedDay`, `tooltipView(for:)`, `formatTooltipDate(_:)` |
| `ios/VMflow/Resources/Localizable.xcstrings` | Modify | Add German translation for `Revenue` (the only genuinely new tooltip key — `Sales` is already present from another usage site with `Verkäufe`) |

No new files. Net additions: ~6 lines model, ~5 lines VM, ~50 lines View, 24 lines catalog.

## Test Strategy

The iOS target has no XCTest harness — verification is build + manual QA per the spec's 11-point checklist. Each task ends with `xcodebuild` to confirm `** BUILD SUCCEEDED **`. After all tasks land, the user runs the full QA checklist on Simulator.

## Branch

Continues on `claude/firmware-cellular-milestone` where the spec was committed at `a483788`. The prior unmerged load-more feature (commits `59b457e`–`93250fe`) sits below this work; stacking is intentional and matches the project's branch convention.

---

## Chunk 1: Implementation

### Task 1: Add `isWeekend` to DailySales and `dailyAverage` to DashboardViewModel

**Files:**
- Modify: `ios/VMflow/Models/Sale.swift` (append after line 63, the closing brace of `struct DailySales`)
- Modify: `ios/VMflow/ViewModels/DashboardViewModel.swift` (insert near other `@Published`/computed declarations, around line 22–27)

- [ ] **Step 1.1: Add the `isWeekend` extension on `DailySales`**

Open `ios/VMflow/Models/Sale.swift`. The `DailySales` struct ends at line 63 with `}`. Append immediately after that closing brace:

```swift

extension DailySales {
    /// True when the day falls on a weekend per the user's current locale
    /// (Sa+So in DE/US; respects user-preferred calendar settings).
    var isWeekend: Bool {
        Calendar.current.isDateInWeekend(date)
    }
}
```

The blank line above the `extension` keyword separates it from the struct.

- [ ] **Step 1.2: Add the `dailyAverage` computed property on `DashboardViewModel`**

Open `ios/VMflow/ViewModels/DashboardViewModel.swift`. Insertion rule (structural, line numbers may drift): place the new computed property **after the last `@Published` declaration in the `// MARK: - Published State` block** and **before the `private let client = SupabaseService.shared.client` line**. At time of writing the file, `@Published var error: String?` is the last published declaration (line 37) and `private let client` is line 39 — insert between them. Insert:

```swift

    /// Average daily revenue over the loaded daily-chart window, including zero-revenue days.
    /// Σ revenue / dailySales.count. The chart header says "30 days" but loadDailyChart()
    /// actually pre-populates 31 daily buckets (`for dayOffset in 0..<31`); we divide by the
    /// actual array count so the average matches what's visually rendered.
    var dailyAverage: Double {
        guard !dailySales.isEmpty else { return 0 }
        return dailySales.reduce(0) { $0 + $1.revenue } / Double(dailySales.count)
    }
```

If the exact line numbers don't match (because the file evolved), the insertion rule is: anywhere in the class body before `private let client = SupabaseService.shared.client`. The property is computed, so its placement is purely organizational.

- [ ] **Step 1.3: Build to verify compilation**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. If `Calendar.current.isDateInWeekend(_:)` doesn't resolve, ensure `import Foundation` is present at the top of `Sale.swift` (it already is per the existing code).

- [ ] **Step 1.4: Commit**

```bash
git -C /Users/lucienkerl/Development/mdb-esp32-cashless add ios/VMflow/Models/Sale.swift ios/VMflow/ViewModels/DashboardViewModel.swift && git -C /Users/lucienkerl/Development/mdb-esp32-cashless commit -m "$(cat <<'EOF'
feat(ios/dashboard): add DailySales.isWeekend + DashboardViewModel.dailyAverage

Pure data additions, no UI wiring yet — Task 2 hooks them into the chart.
isWeekend uses Calendar.current.isDateInWeekend(_:) which respects locale.
dailyAverage divides by dailySales.count rather than a hardcoded 30 to
remain robust to the existing 31-bucket fence-post in loadDailyChart.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Wire chart with weekend coloring, average line, and drag-to-scrub tooltip

**Files:**
- Modify: `ios/VMflow/Views/Dashboard/DashboardView.swift:158–192` (replace the entire chart `if/else` block — both the chart branch and the empty-state else-branch)
- Modify: `ios/VMflow/Views/Dashboard/DashboardView.swift` (add `@State private var selectedDate: Date?` near other view state declarations, around line 13; add `selectedDay`, `tooltipView(for:)`, `formatTooltipDate(_:)` as private members of `DashboardView`)

- [ ] **Step 2.1: Add `@State` for the selected date**

Find the existing `@State` declaration near line 13 of `DashboardView.swift`:

```swift
    /// Whether a refill tour is currently saved/in-progress.
    @State private var hasActiveRefill = false
```

Append right after that line:

```swift

    /// Selected date for chart drag-to-scrub. nil = no tooltip visible.
    @State private var selectedDate: Date?
```

- [ ] **Step 2.2: Replace the chart if/else with the extended version**

Find lines **158–192** in `DashboardView.swift` — the entire `if !viewModel.dailySales.isEmpty { Chart(...) ... } else { RoundedRectangle ... }` block. Replace the whole if/else (both branches) with the block below. The else-branch is preserved verbatim so the replacement is a clean text-block swap rather than a stitch:

```swift
            if !viewModel.dailySales.isEmpty {
                Chart {
                    ForEach(viewModel.dailySales) { day in
                        BarMark(
                            x: .value("Date", day.date, unit: .day),
                            y: .value("Revenue", day.revenue)
                        )
                        .foregroundStyle(day.isWeekend ? Color.blue.opacity(0.45).gradient : Color.blue.gradient)
                        .cornerRadius(3)
                    }

                    if viewModel.dailyAverage > 0 {
                        RuleMark(y: .value("Avg", viewModel.dailyAverage))
                            .foregroundStyle(.orange)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                            .annotation(position: .topTrailing, alignment: .trailing, spacing: 2) {
                                Text("Ø \(formatCurrency(viewModel.dailyAverage))")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                    }

                    if let selectedDate, let day = selectedDay {
                        RuleMark(x: .value("Selected", day.date, unit: .day))
                            .foregroundStyle(.gray.opacity(0.35))
                            .annotation(
                                position: .top,
                                alignment: .center,
                                spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                tooltipView(for: day)
                            }
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        AxisGridLine()
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        if let revenue = value.as(Double.self) {
                            AxisValueLabel {
                                Text(formatCurrencyCompact(revenue))
                            }
                        }
                        AxisGridLine()
                    }
                }
                .frame(height: 200)
                .animation(.smooth, value: selectedDate)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
                    .frame(height: 200)
                    .overlay {
                        Text("No sales data")
                            .foregroundStyle(.secondary)
                    }
            }
```

Key changes vs the original:
- `Chart(viewModel.dailySales) { day in ... }` → `Chart { ForEach(viewModel.dailySales) { day in ... } ... }` (so we can mix the bar `ForEach` with `RuleMark`s for avg + selection in the same chart body)
- Bar `foregroundStyle` is now conditional on `day.isWeekend`
- Two new `RuleMark`s: one for avg (gated on `dailyAverage > 0`), one for selection (gated on `selectedDate != nil`)
- New modifiers: `.chartXSelection(value: $selectedDate)` and `.animation(.smooth, value: selectedDate)`

- [ ] **Step 2.3: Add `selectedDay`, `tooltipView`, `formatTooltipDate` helpers**

Find the `// MARK: - Helpers` comment in `DashboardView.swift` (currently at line 275; locate via search rather than fixed line number). Insert these three private members at the start of that section (immediately after the `// MARK: - Helpers` comment, before `formatCurrency`):

```swift
    private var selectedDay: DailySales? {
        guard let selectedDate else { return nil }
        return viewModel.dailySales.first {
            Calendar.current.isDate($0.date, inSameDayAs: selectedDate)
        }
    }

    @ViewBuilder
    private func tooltipView(for day: DailySales) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formatTooltipDate(day.date))
                .font(.caption.weight(.semibold))
            HStack(spacing: 12) {
                Text("Revenue")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatCurrency(day.revenue))
                    .monospacedDigit()
            }
            .font(.caption2)
            HStack(spacing: 12) {
                Text("Sales")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(day.count)")
                    .monospacedDigit()
            }
            .font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .frame(minWidth: 140)
    }

    private func formatTooltipDate(_ date: Date) -> String {
        // Date.FormatStyle is locale-aware out of the box.
        // - en: "Wed, 15 Apr"
        // - de: "Mi., 15. Apr."
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
```

- [ ] **Step 2.4: Build to verify compilation**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

If the build complains about `chartXSelection`, `RuleMark.annotation(overflowResolution:)`, or `.smooth` not being available, verify the deployment target is iOS 17+ in `ios/project.yml` (line 5: `iOS: "17.0"`) — the spec confirms it is.

If the build complains about a `ForEach` expecting `RandomAccessCollection` etc., the cause is usually a missing `.id(\.id)` or import issue. The above pattern (`ForEach(viewModel.dailySales)` with `DailySales: Identifiable`) works because `DailySales.id == Date` already.

- [ ] **Step 2.5: Commit**

```bash
git -C /Users/lucienkerl/Development/mdb-esp32-cashless add ios/VMflow/Views/Dashboard/DashboardView.swift && git -C /Users/lucienkerl/Development/mdb-esp32-cashless commit -m "$(cat <<'EOF'
feat(ios/dashboard): chart drag-to-scrub tooltip + avg line + weekend coloring

Replaces the simple Chart(dailySales) { BarMark } with a composed Chart that
mixes weekend-conditional bars, an orange dashed avg-line RuleMark with
"Ø XX,XX €" annotation, and a selection RuleMark driven by chartXSelection.
Selection state is held in @State selectedDate; tooltip renders date,
revenue, and sales count over a regularMaterial card. iOS 17+ APIs
(chartXSelection, overflowResolution, .smooth animation) — deployment
target is 17.0 in project.yml.

Strings "Revenue" / "Sales" hit the source language; German translations
follow in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add German translation for "Revenue"

**Files:**
- Modify: `ios/VMflow/Resources/Localizable.xcstrings` (one new entry)

`Sales` already exists in the catalog with the German value `Verkäufe` (verified pre-plan — extracted from another usage site). Only `Revenue` is new and needs a translation. Xcode will have auto-extracted the `Revenue` key into the catalog when Task 2's build ran — but typically with no `localizations` block, just an `extractionState` marker.

- [ ] **Step 3.1: Verify the catalog state after Task 2's build**

```bash
python3 -c "
import json
d = json.load(open('/Users/lucienkerl/Development/mdb-esp32-cashless/ios/VMflow/Resources/Localizable.xcstrings'))
print('Revenue:', json.dumps(d['strings'].get('Revenue', 'MISSING'), indent=2))
print('---')
print('Sales:', json.dumps(d['strings'].get('Sales', 'MISSING'), indent=2))
"
```

Expected:
- `Revenue`: present (likely `{ "extractionState": "..." }` or similar with no `localizations` block) — needs the translation.
- `Sales`: already has `localizations.de.stringUnit.value = "Verkäufe"` — leave untouched.

If `Revenue` is `MISSING`, Task 2's build didn't auto-extract it. Re-run Task 2's build first:
```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -5
```

If `Sales` is missing or has changed, stop and escalate — that would mean another part of the catalog drifted.

- [ ] **Step 3.2: Add the German translation for "Revenue"**

Open `ios/VMflow/Resources/Localizable.xcstrings`. Locate the `Revenue` entry (search for `"Revenue" :`). Replace its body with:

```json
    "Revenue" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Umsatz"
          }
        }
      }
    },
```

If Xcode added a `comment` / `isCommentAutoGenerated` / `extractionState` field on the entry, **preserve those fields** alongside the new `localizations` block (merge, don't replace). Removing `extractionState` would cause Xcode to mark the entry as stale on the next build.

- [ ] **Step 3.3: Do NOT modify the `Sales` entry**

Verify in the diff that `Sales` is unchanged from its pre-plan state. The plan does NOT add or replace `Sales` — it's already complete.

- [ ] **Step 3.4: Validate the JSON parses**

```bash
python3 -c "import json; json.load(open('/Users/lucienkerl/Development/mdb-esp32-cashless/ios/VMflow/Resources/Localizable.xcstrings'))" && echo "JSON valid"
```

Expected: `JSON valid`.

- [ ] **Step 3.5: Build to verify Xcode is happy**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. Xcode may add or normalize metadata fields (`extractionState`, `sourceLanguage`) on the `Revenue` entry — that's fine; do not fight Xcode's edits.

- [ ] **Step 3.6: Commit**

```bash
git -C /Users/lucienkerl/Development/mdb-esp32-cashless add ios/VMflow/Resources/Localizable.xcstrings && git -C /Users/lucienkerl/Development/mdb-esp32-cashless commit -m "$(cat <<'EOF'
i18n(ios): add German translation for chart tooltip — Revenue → Umsatz

Sales → Verkäufe already exists in the catalog from another usage site.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Manual QA on iOS Simulator

Run through the spec's 11-point QA checklist. The implementation is feature-complete after Task 3; this task only verifies behavior.

**Setup:**
```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 15' -configuration Debug build
# Then open the simulator (Cmd+R from Xcode after `xed ios/VMflow.xcodeproj`).
```

- [ ] **Step 4.1: Initial-Load** — Dashboard zeigt 30+1 Säulen, Wochenend-Säulen sind erkennbar heller blau, gestrichelte orange Avg-Linie + "Ø XX,XX €"-Label rechts oben sichtbar. Kein Tooltip.

- [ ] **Step 4.2: Drag-to-Scrub** — Finger auf das Chart legen → graue vertikale Linie + Tooltip erscheinen, beide rasten auf den nächsten Tag.

- [ ] **Step 4.3: Scrubben** — Finger nach rechts/links ziehen → Tooltip wandert smooth zur nächsten Säule mit aktualisierten Werten.

- [ ] **Step 4.4: Lift** — Finger loslassen → Hilfslinie + Tooltip verschwinden.

- [ ] **Step 4.5: Tooltip-Inhalt** — Datum lokalisiert ("Wed, 15 Apr" en / "Mi., 15. Apr." de), Umsatz mit zwei Nachkommastellen + Currency-Symbol, Verkaufsanzahl als Integer.

- [ ] **Step 4.6: Null-Tag scrubben** — Tooltip auf einem Tag ohne Sales zeigt "0,00 €" und "0".

- [ ] **Step 4.7: Edge-Lokationen** — Scrubben auf den ersten und letzten Tag → Tooltip wird nicht am Chart-Rand abgeschnitten.

- [ ] **Step 4.8: Avg-Linien-Korrektheit** — Avg-Linie liegt sichtbar auf der korrekten Y-Höhe; manuell verifizierbar: `Σrevenue / dailySales.count ≈ angezeigter Wert` (Σ = monthRevenue ist eine grobe Annäherung — nicht identisch, da monthRevenue nur den Kalendermonat zählt).

- [ ] **Step 4.9: Wochenend-Erkennung** — Sa und So sind heller blau, alle anderen Tage Standard-Blau.

- [ ] **Step 4.10: Empty-State** — Test-Account ohne 30-Tage-Sales → graue "No sales data"-Box, weder Avg-Linie noch Tooltip rendern.

- [ ] **Step 4.11: Locale-Switch** — Simulator auf Deutsch (Settings → General → Language & Region → German) → Tooltip zeigt "Umsatz" / "Verkäufe" / "Mi., 15. Apr." statt "Revenue" / "Sales" / "Wed, 15 Apr".

- [ ] **Step 4.12: No further commit needed** — Wenn alle Schritte grün, Arbeit ist done. Bei Fail: gezielten Fix in der entsprechenden Datei machen, neuen Commit.

---

## Done Criteria

- All four tasks complete with green builds.
- All 11 manual QA checks pass on Simulator.
- Three commits stacked on `claude/firmware-cellular-milestone`:
  1. `feat(ios/dashboard): add DailySales.isWeekend + DashboardViewModel.dailyAverage`
  2. `feat(ios/dashboard): chart drag-to-scrub tooltip + avg line + weekend coloring`
  3. `i18n(ios): add German translation for chart tooltip — Revenue → Umsatz` *(Sales already in catalog from another usage site)*

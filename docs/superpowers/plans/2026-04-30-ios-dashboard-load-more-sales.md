# iOS Dashboard "Load More" Recent Sales — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a time-windowed "Load more" button to the iOS Dashboard's Recent Sales section so users can scroll back through history (today → 7d → 14d → 21d → …) indefinitely.

**Architecture:** Extend `DashboardViewModel` with three new `@Published` properties (`recentSalesDaysBack`, `hasMoreSales`, `isLoadingMoreSales`) and a `loadMoreRecentSales()` method. Refactor `loadRecentSales()` to use a date-window filter (`gte("created_at", ...)`) instead of a hard `.limit(20)`. Update `DashboardView` to drop the `prefix(10)` slice and render a centered button below the day-grouped sales list.

**Tech Stack:** SwiftUI, Swift Concurrency (`async`/`await`), `Supabase` Swift SDK, Xcode String Catalog (`Localizable.xcstrings`).

**Spec:** [`docs/superpowers/specs/2026-04-30-ios-dashboard-load-more-sales-design.md`](../specs/2026-04-30-ios-dashboard-load-more-sales-design.md)

---

## File Inventory

| File | Action | Responsibility |
|------|--------|----------------|
| `ios/VMflow/ViewModels/DashboardViewModel.swift` | Modify | Add window state + `loadMoreRecentSales()`; refactor `loadRecentSales()` to use date-window filter |
| `ios/VMflow/Views/Dashboard/DashboardView.swift` | Modify | Drop `prefix(10)`; add `loadMoreButton` subview wired to ViewModel |
| `ios/VMflow/Resources/Localizable.xcstrings` | Modify | Add German translations for "Load more" and "Show last %lld days" |

No new files. The change is two-call-site, ~80 lines net additions in ViewModel + ~30 lines in View + 2 entries in xcstrings.

## Test Strategy

The iOS target has **no XCTest suite** in this repo (no `ios/VMflowTests/` directory) — verification is **build + manual QA on simulator**, not automated. Each task ends with an `xcodebuild` compile check; the final task walks through the spec's 8-item manual QA checklist. For regression-significant logic (the day-arithmetic in `loadMoreRecentSales`), the steps include a quick mental-trace verification before commit.

## Branch / Worktree

Work continues on the current branch `claude/firmware-cellular-milestone` where the spec was committed. No new worktree required — this is a focused 3-file change building directly on top of the spec commit.

---

## Chunk 1: Implementation

### Task 1: Extend DashboardViewModel with time-window state and `loadMoreRecentSales()`

**Files:**
- Modify: `ios/VMflow/ViewModels/DashboardViewModel.swift:22-27` (add new `@Published` properties)
- Modify: `ios/VMflow/ViewModels/DashboardViewModel.swift:181-242` (refactor `loadRecentSales`)
- Modify: `ios/VMflow/ViewModels/DashboardViewModel.swift:243` (append `loadMoreRecentSales` method before final `}`)

- [ ] **Step 1.1: Add three new `@Published` properties below `recentSales`**

Insert after line 22 (after `@Published var recentSales: [SaleWithMachine] = []`):

```swift
    /// Number of days back from start_of_today the recent-sales window covers.
    /// 0 = today only; 6 = last 7 days; 13 = last 14 days; 7N−1 after N "load more" taps.
    @Published var recentSalesDaysBack: Int = 0

    /// Becomes false when a "load more" tap returns no additional sales (history exhausted).
    /// Resets to true whenever a window-respecting reload brings in more sales than before
    /// (e.g. realtime delivery into the current window).
    @Published var hasMoreSales: Bool = true

    /// True while a `loadMoreRecentSales` fetch is in flight — drives the button spinner.
    @Published var isLoadingMoreSales: Bool = false
```

- [ ] **Step 1.2: Refactor `loadRecentSales()` to use a date-window filter and the recovery rule**

Replace lines 181–189 (the query block at the top of `loadRecentSales`):

```swift
    private func loadRecentSales() async throws {
        // Compute window start: start_of_today − recentSalesDaysBack days.
        // daysBack=0 → start_of_today (only today's sales since midnight, NOT last 24h).
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let windowStart = calendar.date(byAdding: .day, value: -recentSalesDaysBack, to: startOfToday)!

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Fetch sales with snapshotted product via FK join.
        let sales: [Sale] = try await client
            .from("sales")
            .select("id, created_at, item_price, item_number, machine_id, embedded_id, channel, product_id, products(name, image_path)")
            .gte("created_at", value: formatter.string(from: windowStart))
            .order("created_at", ascending: false)
            .execute()
            .value
```

Then at the **very end** of `loadRecentSales` (replace the final `recentSales = sales.map { ... }` block at lines 227–242 with):

```swift
        let countBefore = recentSales.count
        recentSales = sales.map { sale in
            let machineName = sale.machineId.flatMap { machineNames[$0] }

            // Prefer snapshotted product from FK join, fallback to tray lookup
            var productName: String? = sale.products?.name
            var productImagePath: String? = sale.products?.imagePath

            if productName == nil, let machineId = sale.machineId, let itemNum = sale.itemNumber {
                let trayProduct = trayProductLookup["\(machineId)_\(itemNum)"]
                productName = trayProduct?.name
                productImagePath = trayProduct?.imagePath
            }

            return SaleWithMachine(sale: sale, machineName: machineName, productName: productName, productImagePath: productImagePath)
        }

        // Recovery: if a reload brought in more sales than before (e.g. realtime delivery
        // into the current window), un-exhaust the load-more button.
        if recentSales.count > countBefore {
            hasMoreSales = true
        }
    }
```

Note: `.limit(20)` is **dropped** — the date filter alone bounds the fetch.

- [ ] **Step 1.3: Add the `loadMoreRecentSales()` method**

Append before the closing `}` of the `DashboardViewModel` class (after line 242, before the final `}` of the class):

```swift
    // MARK: - Load More

    /// Expand the recent-sales window: today (1 day) → 7 days → 14 days → 21 days → …
    /// Each tap adds 7 more days; first tap jumps from 1 to 7 (i.e. +6 days).
    func loadMoreRecentSales() async {
        guard !isLoadingMoreSales, hasMoreSales else { return }

        let previousDaysBack = recentSalesDaysBack
        let nextDaysBack = previousDaysBack == 0 ? 6 : previousDaysBack + 7

        isLoadingMoreSales = true
        defer { isLoadingMoreSales = false }

        let countBefore = recentSales.count
        recentSalesDaysBack = nextDaysBack

        do {
            try await loadRecentSales()
            // If the wider window returned the exact same number of sales, history is exhausted.
            if recentSales.count == countBefore {
                hasMoreSales = false
            }
        } catch is CancellationError {
            // Refresh cancellation: revert window so a follow-up tap retries cleanly.
            recentSalesDaysBack = previousDaysBack
        } catch {
            // Server/network error: revert window so a follow-up tap retries.
            recentSalesDaysBack = previousDaysBack
            self.error = error.localizedDescription
        }
    }
```

- [ ] **Step 1.4: Mental-trace the day arithmetic before building**

Verify the progression matches the spec:

| Tap # | `recentSalesDaysBack` before | `nextDaysBack` | Window size (days incl. today) | Caption next-tap-total |
|-------|-----------------------------|----------------|-------------------------------|----------------------|
| 1     | 0                           | 6              | 7                             | 14                   |
| 2     | 6                           | 13             | 14                            | 21                   |
| 3     | 13                          | 20             | 21                            | 28                   |
| 4     | 20                          | 27             | 28                            | 35                   |

Rollback math (when next fetch errors): `previousDaysBack` is captured *before* mutation, so revert is one assignment — no offset traps.

- [ ] **Step 1.5: Build to verify compilation**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **` near the end. If it fails on missing `gte` overload, the existing pattern at lines 68 and 153 is the reference — they pass `value:` (named argument) of the formatted string.

- [ ] **Step 1.6: Commit**

```bash
git -C /Users/lucienkerl/Development/mdb-esp32-cashless add ios/VMflow/ViewModels/DashboardViewModel.swift && git -C /Users/lucienkerl/Development/mdb-esp32-cashless commit -m "$(cat <<'EOF'
feat(ios/dashboard): time-windowed recent sales fetch + loadMore method

Drops the .limit(20) cap in favor of a date-window filter (gte created_at).
Adds recentSalesDaysBack / hasMoreSales / isLoadingMoreSales state and a
loadMoreRecentSales() that grows the window 0d → 6d → 13d → 20d → … on tap,
with rollback on error and end-of-history detection. View still slices via
prefix(10) at this point — UI wiring follows in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Wire DashboardView to the new state and add the load-more button

**Files:**
- Modify: `ios/VMflow/Views/Dashboard/DashboardView.swift:204-231` (replace `recentSalesSection`)
- Modify: `ios/VMflow/Views/Dashboard/DashboardView.swift` (add `loadMoreButton` computed view below `recentSalesSection`)

- [ ] **Step 2.1: Replace `recentSalesSection` to drop `prefix(10)` and append the button**

Replace lines 204–231:

```swift
    private var recentSalesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Sales")
                .font(.headline)

            if viewModel.recentSales.isEmpty && !viewModel.isLoading {
                Text("No recent sales")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                let grouped = groupDashboardSalesByDay(viewModel.recentSales)
                ForEach(grouped, id: \.date) { group in
                    DaySectionHeader(label: dayLabel(for: group.date), count: group.sales.count)
                    ForEach(group.sales) { item in
                        RecentSaleRow(item: item)
                    }
                }
            }

            if viewModel.hasMoreSales {
                loadMoreButton
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }
```

Notes:
- `prefix(10)` is gone — `viewModel.recentSales` now holds the full window from the ViewModel.
- The button is appended **inside** the section's `VStack`, so it sits below the last day group and inherits the section's padding/background.
- The button is hidden by setting visibility on the whole subview (no `.opacity(0)` left behind in the layout).

- [ ] **Step 2.2: Add `loadMoreButton` as a private computed view**

Insert immediately after the closing `}` of `recentSalesSection` (i.e. after the new line that replaced the old line 231):

```swift
    private var loadMoreButton: some View {
        // Days the *next* tap would show. Current visible window = recentSalesDaysBack + 1 days
        // (since daysBack counts back from today inclusive). Each tap adds +7 days, except the
        // very first which goes 1 → 7 (i.e. +6 days).
        let nextDaysTotal: Int = {
            if viewModel.recentSalesDaysBack == 0 { return 7 }
            return (viewModel.recentSalesDaysBack + 1) + 7
        }()

        return VStack(spacing: 4) {
            Button {
                Task { await viewModel.loadMoreRecentSales() }
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isLoadingMoreSales {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text("Load more")
                }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isLoadingMoreSales)

            Text("Show last \(nextDaysTotal) days")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
```

- [ ] **Step 2.3: Build to verify compilation**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

If the build complains about `Show last \(nextDaysTotal) days` not being a localizable format, swap to `Text(String(localized: "Show last \(nextDaysTotal) days"))` — but SwiftUI's `Text` initializer already accepts localized format strings out of the box, so the plain form should work.

- [ ] **Step 2.4: Commit**

```bash
git -C /Users/lucienkerl/Development/mdb-esp32-cashless add ios/VMflow/Views/Dashboard/DashboardView.swift && git -C /Users/lucienkerl/Development/mdb-esp32-cashless commit -m "$(cat <<'EOF'
feat(ios/dashboard): render Load more button in Recent Sales section

Drops the prefix(10) UI cap so the section reflects the ViewModel's full
window. Appends a centered, bordered Load-more button with a caption
previewing the next-tap window size ("Show last 7 days" / "Show last 14 days"
/ ...). Hidden when hasMoreSales is false; spinner replaces the icon while
isLoadingMoreSales is true.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add German translations to the String Catalog

**Files:**
- Modify: `ios/VMflow/Resources/Localizable.xcstrings` (add two entries)

The Xcode String Catalog is a JSON file. New strings get auto-extracted by Xcode the next time the project builds, but pre-seeding the German translations avoids a "stale" state in the catalog.

- [ ] **Step 3.1: Add "Load more" entry**

Open `ios/VMflow/Resources/Localizable.xcstrings`. In the top-level `"strings"` object, add (alphabetically near other `L` entries — exact placement is not significant since Xcode re-sorts on save):

```json
    "Load more" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Mehr laden"
          }
        }
      }
    },
```

- [ ] **Step 3.2: Add "Show last %lld days" entry**

Swift `Text("Show last \(Int) days")` produces a format key `Show last %lld days` in the catalog. Add:

```json
    "Show last %lld days" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Letzte %lld Tage anzeigen"
          }
        }
      }
    },
```

- [ ] **Step 3.3: Validate the JSON parses**

```bash
python3 -c "import json; json.load(open('/Users/lucienkerl/Development/mdb-esp32-cashless/ios/VMflow/Resources/Localizable.xcstrings'))" && echo "JSON valid"
```

Expected output: `JSON valid`. A trailing comma or missing brace will surface here — fix before building.

- [ ] **Step 3.4: Build (Xcode auto-syncs the catalog)**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. Xcode may add `extractionState` or `sourceLanguage` metadata to the entries on build — that's fine.

- [ ] **Step 3.5: Commit**

```bash
git -C /Users/lucienkerl/Development/mdb-esp32-cashless add ios/VMflow/Resources/Localizable.xcstrings && git -C /Users/lucienkerl/Development/mdb-esp32-cashless commit -m "$(cat <<'EOF'
i18n(ios): add German translations for Load more button strings

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Manual QA on iOS Simulator

The spec's 8-point QA list is the acceptance criteria. Run through it on a Simulator (iPhone 15 or similar) connected to a dev backend with real sales data.

**Setup:**
```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless && xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'platform=iOS Simulator,name=iPhone 15' -configuration Debug build
# Then open the simulator and launch the VMflow app, or press Cmd+R in Xcode after `xed ios/VMflow.xcodeproj`.
```

- [ ] **Step 4.1: Initial-Load** — Launch app on a logged-in account. Dashboard "Recent Sales" shows only today's sales (or "No recent sales" if today is empty). Button visible with caption "Show last 7 days".

- [ ] **Step 4.2: 1st Tap** — Tap "Load more". Spinner briefly appears. List grows to include yesterday and the previous 5 days (7 days total visible). Caption updates to "Show last 14 days".

- [ ] **Step 4.3: Multiple taps** — Tap 3–4 more times. Each tap adds another 7 days. Caption increments correctly: 21, 28, 35, …

- [ ] **Step 4.4: End-of-history** — Either pick an account with limited history, or keep tapping until the list size stops growing. After the next-empty tap, the button disappears.

- [ ] **Step 4.5: Empty Today** — On an account with no today-sales: section shows "No recent sales" *and* the load-more button. Tapping it loads older sales.

- [ ] **Step 4.6: Realtime preserves window** — Expand window to 14 days. From a separate machine, push a new sale via MQTT (or insert directly into Supabase). Within 1–2 seconds, the new sale appears in "Today" section. Window stays at 14 days. Caption stays at "Show last 21 days".

- [ ] **Step 4.7: Pull-to-refresh preserves window** — Expand window to 14 days. Pull down to refresh. Spinner appears, then the same 14-day window re-renders. Caption unchanged.

- [ ] **Step 4.8: Network error rollback** — Enable Airplane Mode on the simulator (Features → Network Link Conditioner → 100% Loss). Tap "Load more". Error surfaces (via existing `error` channel — currently silent in UI, but `viewModel.error` is set). Window does NOT advance — caption still reads the previous "Show last X days". Disable Airplane Mode and tap again — load succeeds.

- [ ] **Step 4.9: German locale** — Set the simulator to German (Settings → General → Language & Region → German). Restart the app. Button reads "Mehr laden", caption reads "Letzte 7 Tage anzeigen" / "Letzte 14 Tage anzeigen" / etc.

- [ ] **Step 4.10: No further commit needed** — If all checks pass, work is done. If a check fails, isolate the cause, fix in the appropriate task's file, and re-run only the failing check.

---

## Done Criteria

- All four tasks complete with green builds.
- All ten Step-4 manual QA checks pass.
- Three commits on `claude/firmware-cellular-milestone`:
  1. `feat(ios/dashboard): time-windowed recent sales fetch + loadMore method`
  2. `feat(ios/dashboard): render Load more button in Recent Sales section`
  3. `i18n(ios): add German translations for Load more button strings`

# Replacement Picker Grouping Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group the product list inside `ReplacementProductPicker` by stock status (In Stock / Out of Stock) and category, with the discontinued product's category surfaced first and not-yet-placed products before already-in-machine ones.

**Architecture:** Client-only feature. `RefillWizardViewModel` gains a `productCategories` field and a `currentCategoryId(forTrayId:)` helper. `ReplacementProductPicker` gains two new parameters (`currentCategoryId`, `categories`), a `stockBuckets` computed property that pipelines filter → partition → group → sort, and a rewritten `Section` body that emits stock mega-headers + category sub-headers + product rows in one continuous list. Separator suppression is wired via an `isLastInGroup` flag on each product row.

**Tech Stack:** SwiftUI 5.9+, Swift 5.9+, iOS 17+ (project target), Xcode 15+. No third-party dependencies.

**Spec:** [docs/superpowers/specs/2026-05-27-picker-grouping-design.md](../specs/2026-05-27-picker-grouping-design.md)

---

## Conventions for this Plan

- **No unit-test target** in the iOS project. TDD-equivalent loop:
  1. Write SwiftUI code.
  2. Run `xcodebuild build` to compile-check.
  3. Add or update a `#Preview` to exercise the new visual state.
  4. Open Xcode → preview canvas → verify the preview renders as described.
- Standard build command (used throughout):
  ```bash
  xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug build 2>&1 | tail -10
  ```
  Expected on success: last line contains `** BUILD SUCCEEDED **`.
- Commit messages follow Conventional Commits with `feat(refill)` / `i18n(refill)` / `refactor(refill)` scope.
- **Xcode auto-extracts xcstrings on build**, sometimes adding spurious `"extractionState": "stale"` markers to the JSON. After Tasks 4 and 7 (and any build that touches `String(localized:)`), check `git diff ios/VMflow/Resources/Localizable.xcstrings` — if the only changes are `+      "extractionState" : "stale",` lines and no other content, revert the file with `git checkout -- ios/VMflow/Resources/Localizable.xcstrings` BEFORE staging. Only stage `Localizable.xcstrings` when you actually added or modified strings yourself (Task 5).
- Each task ends with a single `xcodebuild` + commit pair. Do NOT bundle multiple tasks into one commit.

---

## File Structure

| File | Responsibility |
|---|---|
| `ios/VMflow/ViewModels/RefillWizardViewModel.swift` | Existing. + `@Published var productCategories: [ProductCategory]`, + load call in `loadData()`, + `currentCategoryId(forTrayId:)` helper. |
| `ios/VMflow/Views/Refill/ReviewStepView.swift` | Existing. + new picker parameters `currentCategoryId` and `categories`, + nested types `StockBucket` / `CategoryGroup`, + `stockBuckets` computed property, + body rewrite with mega-headers + sub-headers, + new "Picker with grouping (typical)" preview. |
| `ios/VMflow/Resources/Localizable.xcstrings` | Existing. + four new keys (`"In Stock"`, `"Out of Stock"`, `"current"`, `"Uncategorized"`) with EN+DE values. |

No new files. Projected size of `ReviewStepView.swift` after change: ~785 lines (currently 665). The 800-line "must extract" threshold from the prior milestone is not crossed, so no file split is planned. If the implementation ends up over 800, extract `ReplacementProductPicker` into its own file in the same task.

---

## Chunk 1: Data Layer

This chunk wires categories into the refill view model and adds the helper that resolves "what category is the slot currently in." After this chunk, no UI has changed yet — we have data ready for the rendering work in Chunk 2.

### Task 1: Add `productCategories` to `RefillWizardViewModel` and load it

**Files:**
- Modify: `ios/VMflow/ViewModels/RefillWizardViewModel.swift`

- [ ] **Step 1.1: Add the published property**

In `RefillWizardViewModel`, near the existing `@Published var availableProducts: [Product] = []` at line 246, add immediately after it:

```swift
    /// Product categories used to label/group products in the replacement
    /// picker. Loaded alongside `availableProducts` in `loadData()`.
    @Published var productCategories: [ProductCategory] = []
```

- [ ] **Step 1.2: Load categories in `loadData()`**

Inside `loadData()` at line 1160, find the existing block that loads `availableProducts` (around lines 1204–1212):

```swift
                let activeProducts: [Product] = try await client
                    .from("products")
                    .select("id, name, image_path, discontinued, sellprice, category")
                    .or("discontinued.is.null,discontinued.eq.false")
                    .order("name", ascending: true)
                    .execute()
                    .value
                self.availableProducts = activeProducts
```

Immediately after that assignment (`self.availableProducts = activeProducts`), insert:

```swift

                // Load categories for the replacement picker's grouping UI.
                // Mirrors ProductsViewModel.loadCategories() — explicit column
                // list and alphabetical order so the decoder is safe against
                // future schema additions.
                let cats: [ProductCategory] = try await client
                    .from("product_category")
                    .select("id, name, company")
                    .order("name", ascending: true)
                    .execute()
                    .value
                self.productCategories = cats
```

- [ ] **Step 1.3: Compile-check**

Run the standard build. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 1.4: Commit**

```bash
git add ios/VMflow/ViewModels/RefillWizardViewModel.swift
git commit -m "feat(refill): load productCategories in RefillWizardViewModel"
```

---

### Task 2: Add `currentCategoryId(forTrayId:)` helper to view model

**Files:**
- Modify: `ios/VMflow/ViewModels/RefillWizardViewModel.swift`

- [ ] **Step 2.1: Add the helper method**

Search the file for the existing helper `func warehouseStockFor(productId:)` (around line 417). Add the new method directly after the closing brace of `remainingWarehouseStock(productId:)` (around line 435), in the same logical "lookup helpers" cluster:

```swift
    /// Look up the category UUID of the product currently in the tray being
    /// replaced. Returns `nil` if (a) no `ReplacementSuggestion` exists for
    /// this tray, (b) the suggestion has no current product (unassigned
    /// slot), (c) the current product isn't in `availableProducts`, or
    /// (d) the product is uncategorized. The replacement picker uses this
    /// to highlight the matching category first.
    func currentCategoryId(forTrayId trayId: UUID) -> UUID? {
        guard let pid = replacements.first(where: { $0.trayId == trayId })?.currentProductId
        else { return nil }
        return availableProducts.first(where: { $0.id == pid })?.category
    }
```

- [ ] **Step 2.2: Compile-check**

Run the standard build. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2.3: Commit**

```bash
git add ios/VMflow/ViewModels/RefillWizardViewModel.swift
git commit -m "feat(refill): add currentCategoryId(forTrayId:) helper to view model"
```

---

## Chunk 2: Grouping Pipeline & UI Scaffolding

This chunk adds the grouping data types, the `stockBuckets` computed pipeline, and the new picker parameters — all with `ReplacementProductPicker` still rendering the old flat list. After this chunk, the data is fully grouped behind the scenes but the UI hasn't switched over yet.

### Task 3: Add nested types and new picker parameters

**Files:**
- Modify: `ios/VMflow/Views/Refill/ReviewStepView.swift`

- [ ] **Step 3.1: Add the new parameters to `ReplacementProductPicker`**

Locate the `ReplacementProductPicker` struct (around line 443). Update its property list to add `currentCategoryId` and `categories` as variables with defaults:

```swift
struct ReplacementProductPicker: View {
    let products: [Product]
    let selectedProductId: UUID?
    let existingSlotsByProduct: [UUID: [Int]]
    let machineLayout: MachineGridLayout
    /// Remaining warehouse stock for the given product, or `nil` when the
    /// caller has no warehouse context (e.g. previews, or no warehouse
    /// selected in the refill wizard). When non-nil the row shows a
    /// stock-count pill; a value of `0` additionally fades the row to mark
    /// it as a poor replacement candidate.
    var remainingStock: (UUID) -> Int? = { _ in nil }
    /// Category UUID of the product currently in the tray being replaced.
    /// `nil` if the tray is unassigned or the current product is uncategorized.
    /// When non-nil, that category is rendered first in each stock bucket.
    var currentCategoryId: UUID? = nil
    /// Category catalogue for name lookup. Empty array is valid — uncategorized
    /// products will still render; products whose `category` UUID is not
    /// present in the array fall back to the "Uncategorized" group.
    var categories: [ProductCategory] = []
    let onSelect: (UUID) -> Void

    @State private var searchText = ""
    @State private var highlightedProductId: UUID?
    // ...
```

Leave everything else in the struct untouched for this task.

- [ ] **Step 3.2: Add nested types for the grouping pipeline**

Inside the same `ReplacementProductPicker` struct, immediately after the `@State` properties and before the existing `private var filteredProducts: [Product]` computed property, insert:

```swift
    // MARK: - Grouping types

    /// Top-level grouping by warehouse stock status.
    private enum StockStatus: String {
        case inStock
        case outOfStock
    }

    /// One stock bucket containing zero or more category groups.
    private struct StockBucket: Identifiable {
        let status: StockStatus
        let categories: [CategoryGroup]
        var id: String { status.rawValue }
        /// Total product count across all categories — shown in the mega-header.
        var totalCount: Int { categories.reduce(0) { $0 + $1.products.count } }
    }

    /// One category's products inside a stock bucket. `category == nil`
    /// represents the "Uncategorized" group rendered at the end.
    private struct CategoryGroup: Identifiable {
        let category: ProductCategory?
        let isCurrent: Bool
        let products: [Product]
        var id: String { category?.id.uuidString ?? "uncategorized" }
    }
```

- [ ] **Step 3.3: Update both existing previews to satisfy the new defaults**

The two existing `#Preview` blocks construct `ReplacementProductPicker` without passing the new arguments. Because `currentCategoryId` and `categories` have defaults, this still compiles — no changes are needed to the previews in this task. Do not touch them.

- [ ] **Step 3.4: Compile-check**

Run the standard build. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3.5: Commit**

```bash
git add ios/VMflow/Views/Refill/ReviewStepView.swift
git commit -m "feat(refill): add grouping types and picker params (no UI yet)"
```

---

### Task 4: Add the `stockBuckets` grouping pipeline

**Files:**
- Modify: `ios/VMflow/Views/Refill/ReviewStepView.swift`

- [ ] **Step 4.1: Add the computed property and helpers**

In `ReplacementProductPicker`, immediately after the existing `fuzzyMatch(query:target:)` function, insert this block:

```swift
    // MARK: - Stock buckets pipeline

    /// Visible product structure for the picker body. Computed on every
    /// re-render — depends only on `searchText`, `products`, `remainingStock`,
    /// `existingSlotsByProduct`, `currentCategoryId`, and `categories`. Pure,
    /// no side effects.
    ///
    /// Pipeline:
    /// 1. Filter by search (existing fuzzyMatch, keep score)
    /// 2. Partition by stock (nil or >0 = inStock, ==0 = outOfStock)
    /// 3. Group by category within each bucket (current first, others A-Z, uncategorized last)
    /// 4. Sort within each (stock × category) group: not-in-machine first, then
    ///    fuzzy score (search-active only), then alphabetical
    private var stockBuckets: [StockBucket] {
        // Step 1: filter by search
        let scored: [(Product, Int?)]
        if searchText.isEmpty {
            scored = products.map { ($0, nil) }
        } else {
            let query = searchText.lowercased()
            scored = products.compactMap { product -> (Product, Int?)? in
                guard let name = product.name?.lowercased() else { return nil }
                guard let s = fuzzyMatch(query: query, target: name) else { return nil }
                return (product, s)
            }
        }

        // Step 2: partition by stock
        var inStock: [(Product, Int?)] = []
        var outOfStock: [(Product, Int?)] = []
        for entry in scored {
            if remainingStock(entry.0.id) == 0 {
                outOfStock.append(entry)
            } else {
                inStock.append(entry)
            }
        }

        // Step 3+4 for each bucket
        let inStockGroups = groupByCategory(inStock)
        let outOfStockGroups = groupByCategory(outOfStock)

        return [
            StockBucket(status: .inStock, categories: inStockGroups),
            StockBucket(status: .outOfStock, categories: outOfStockGroups)
        ].filter { !$0.categories.isEmpty }
    }

    /// Group a stock-bucket's products by category, sort categories
    /// (current → alphabetical → uncategorized), and sort products within
    /// each category. Pure function.
    private func groupByCategory(_ scored: [(Product, Int?)]) -> [CategoryGroup] {
        // Index categories by UUID for fast name lookup. `reduce(into:)`
        // is crash-safe if `categories` ever contains duplicate IDs (later
        // value wins) — unlike `Dictionary(uniqueKeysWithValues:)` which
        // traps at runtime.
        let categoryById: [UUID: ProductCategory] = categories.reduce(into: [:]) {
            $0[$1.id] = $1
        }

        // Bucket products by category UUID; nil category → uncategorized bucket
        var byCategoryId: [UUID?: [(Product, Int?)]] = [:]
        for entry in scored {
            let key = entry.0.category
            byCategoryId[key, default: []].append(entry)
        }

        // Sort products within each category bucket using the multi-key sort:
        // (not-in-machine, fuzzyScore?, alphabetical)
        func sortKey(_ entry: (Product, Int?)) -> (Bool, Int, String) {
            let inMachine = existingSlotsByProduct[entry.0.id]?.isEmpty == false
            let score = entry.1 ?? 0
            let name = entry.0.name ?? ""
            // Treat empty/nil name as last by prepending a high-codepoint marker
            let nameKey = name.isEmpty ? "\u{FFFF}" : name.lowercased()
            return (inMachine, score, nameKey)
        }
        for key in byCategoryId.keys {
            byCategoryId[key]?.sort { a, b in
                let ka = sortKey(a)
                let kb = sortKey(b)
                if ka.0 != kb.0 { return !ka.0 && kb.0 }
                if ka.1 != kb.1 { return ka.1 < kb.1 }
                return ka.2.localizedCaseInsensitiveCompare(kb.2) == .orderedAscending
            }
        }

        // Build CategoryGroup list with ordering: current → A-Z → uncategorized last
        var orderedGroups: [CategoryGroup] = []

        // 1. Current category (if any and has products)
        if let curId = currentCategoryId,
           let curCat = categoryById[curId],
           let entries = byCategoryId[curId], !entries.isEmpty {
            orderedGroups.append(
                CategoryGroup(category: curCat, isCurrent: true, products: entries.map(\.0))
            )
        }

        // 2. Other named categories alphabetically
        let otherCategoryIds = byCategoryId.keys
            .compactMap { $0 } // drop the nil key (uncategorized)
            .filter { $0 != currentCategoryId }
        let sortedOthers = otherCategoryIds
            .compactMap { id -> (UUID, ProductCategory)? in
                guard let cat = categoryById[id] else { return nil }
                return (id, cat)
            }
            .sorted { $0.1.name.localizedCaseInsensitiveCompare($1.1.name) == .orderedAscending }
        for (id, cat) in sortedOthers {
            guard let entries = byCategoryId[id], !entries.isEmpty else { continue }
            orderedGroups.append(
                CategoryGroup(category: cat, isCurrent: false, products: entries.map(\.0))
            )
        }

        // 3. Unknown-category-UUID products: products whose category UUID was
        //    set but doesn't exist in `categories`. Fold into the uncategorized
        //    bucket as a safe fallback. We deliberately DON'T filter out
        //    `k == currentCategoryId` here — if the current product's category
        //    UUID also isn't in the catalogue (rare race), those products
        //    would otherwise be dropped entirely. They land in uncategorized.
        let unknownCategoryEntries: [(Product, Int?)] = byCategoryId
            .filter { key, _ in
                guard let k = key else { return false }
                return categoryById[k] == nil
            }
            .flatMap { $0.value }

        #if DEBUG
        if !unknownCategoryEntries.isEmpty {
            let ids = Set(unknownCategoryEntries.compactMap { $0.0.category })
            print("[RefillWizard] unknown category UUID(s) in picker: \(ids)")
        }
        #endif

        // 4. Uncategorized group (nil category) + any unknown-category fallback
        var uncategorizedEntries: [(Product, Int?)] = byCategoryId[nil] ?? []
        uncategorizedEntries.append(contentsOf: unknownCategoryEntries)
        if !uncategorizedEntries.isEmpty {
            // Re-sort the merged uncategorized bucket
            uncategorizedEntries.sort { a, b in
                let ka = sortKey(a)
                let kb = sortKey(b)
                if ka.0 != kb.0 { return !ka.0 && kb.0 }
                if ka.1 != kb.1 { return ka.1 < kb.1 }
                return ka.2.localizedCaseInsensitiveCompare(kb.2) == .orderedAscending
            }
            orderedGroups.append(
                CategoryGroup(category: nil, isCurrent: false, products: uncategorizedEntries.map(\.0))
            )
        }

        return orderedGroups
    }
```

- [ ] **Step 4.2: Compile-check**

Run the standard build. Expected: `** BUILD SUCCEEDED **`.

If Xcode added `extractionState: "stale"` lines to `Localizable.xcstrings`, revert that file (see Conventions).

- [ ] **Step 4.3: Commit**

```bash
git add ios/VMflow/Views/Refill/ReviewStepView.swift
git commit -m "feat(refill): add stockBuckets grouping pipeline (no UI yet)"
```

---

## Chunk 3: UI Rendering, Wire-up, and Verification

This chunk swaps the picker body over to the new grouped layout, adds the localization strings, wires the call site in `ReviewStepView`, and adds the new preview.

### Task 5: Add the four new localizable strings (EN+DE)

**Files:**
- Modify: `ios/VMflow/Resources/Localizable.xcstrings`

- [ ] **Step 5.1: Add four new keys to the xcstrings catalog**

The file is JSON. Add these four entries inside the `"strings"` object (anywhere in the existing list — JSON object key order is informational):

```json
    "In Stock" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Auf Lager"
          }
        }
      }
    },
    "Out of Stock" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Nicht auf Lager"
          }
        }
      }
    },
    "current" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "aktuell"
          }
        }
      }
    },
    "Uncategorized" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Ohne Kategorie"
          }
        }
      }
    },
```

Verify the file is still valid JSON with:
```bash
python3 -c "import json; json.load(open('ios/VMflow/Resources/Localizable.xcstrings'))" && echo OK
```

- [ ] **Step 5.2: Compile-check**

Run the standard build. Expected: `** BUILD SUCCEEDED **`. Missing xcstrings keys would not break compilation anyway — this check just verifies the JSON edit didn't break the file.

After the build, check `git diff ios/VMflow/Resources/Localizable.xcstrings`. Xcode may have re-injected `"extractionState": "stale"` on the four keys you just added (or on unrelated existing keys). Keep only the legitimate additions and revert any spurious `extractionState` flips with targeted `git checkout -p` or by hand-editing the diff. The four new keys should NOT have `extractionState: "stale"` in the committed file.

- [ ] **Step 5.3: Commit**

```bash
git add ios/VMflow/Resources/Localizable.xcstrings
git commit -m "i18n(refill): add picker grouping strings (EN+DE)"
```

---

### Task 6: Rewrite picker body with grouped rendering

**Files:**
- Modify: `ios/VMflow/Views/Refill/ReviewStepView.swift`

- [ ] **Step 6.1: Add the header-row helper views**

Inside `ReplacementProductPicker`, after the `groupByCategory(_:)` private function from Task 4, insert:

```swift
    // MARK: - Header row helpers

    /// Mega-header rendered above an entire stock bucket. Only shown when
    /// both `stockBuckets` are present (i.e. some products are in stock AND
    /// some are out of stock). With only one bucket, the mega-header is
    /// suppressed and category sub-headers stand alone.
    @ViewBuilder
    private func stockMegaHeader(_ bucket: StockBucket) -> some View {
        let title: String = {
            switch bucket.status {
            case .inStock: return String(localized: "In Stock")
            case .outOfStock: return String(localized: "Out of Stock")
            }
        }()

        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(bucket.totalCount)")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .listRowBackground(Color(.systemGroupedBackground))
        .listRowSeparator(.hidden)
        .selectionDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(title), \(bucket.totalCount) \(bucket.totalCount == 1 ? "product" : "products")"
        )
        .accessibilityAddTraits(.isHeader)
    }

    /// Sub-header for one category within a stock bucket. Highlights the
    /// current category with accent color and an "· aktuell" suffix.
    @ViewBuilder
    private func categorySubHeader(_ group: CategoryGroup) -> some View {
        let name: String = group.category?.name ?? String(localized: "Uncategorized")
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(group.isCurrent ? Color.accentColor : .secondary)
            if group.isCurrent {
                Text(verbatim: "· ")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("current")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.lowercase)
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
        .listRowSeparator(.hidden)
        .selectionDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.isCurrent ? "\(name), current category" : name)
        .accessibilityAddTraits(.isHeader)
    }
```

- [ ] **Step 6.2: Replace the body's product list section**

Locate the `body` of `ReplacementProductPicker` (around line 491). Find the `Section { ForEach(filteredProducts) { product in ... } ... }` block — the one with the product rows + `ContentUnavailableView.search` fallback. Replace it with the grouped rendering below. Important: leave the `if machineLayout.rowCount > 0 { Section(...) { MachineLayoutGrid... } }` section ABOVE it untouched. Leave the `.searchable`, `.navigationTitle`, and `.navigationBarTitleDisplayMode` modifiers below the `List` untouched. Replace ONLY the products-section block.

```swift
                let buckets = stockBuckets
                let showMegaHeaders = buckets.count > 1

                Section {
                    if buckets.isEmpty, !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(buckets) { bucket in
                        if showMegaHeaders {
                            stockMegaHeader(bucket)
                        }
                        ForEach(bucket.categories) { group in
                            categorySubHeader(group)
                            ForEach(Array(group.products.enumerated()), id: \.element.id) { idx, product in
                                productRow(
                                    product: product,
                                    isLastInGroup: idx == group.products.count - 1
                                )
                            }
                        }
                    }
                }
```

- [ ] **Step 6.3: Extract the existing product row into a helper**

Just before the closing `}` of `ReplacementProductPicker`, immediately after the existing `handleGridTap(slot:proxy:)` method, add the product-row builder. This consolidates the row rendering that previously lived inline inside the `ForEach`.

**Why `isLastInGroup` alone suffices for separator suppression:** Each `CategoryGroup`'s last product carries `isLastInGroup = true`, which sets `.listRowSeparator(.hidden, edges: .bottom)`. That correctly suppresses the separator above whatever comes next — whether that's a category sub-header (next group in the same bucket) OR a stock mega-header (start of the next bucket). No additional "last-in-bucket" flag is needed because the same row IS the last of its category group either way.

```swift
    @ViewBuilder
    private func productRow(product: Product, isLastInGroup: Bool) -> some View {
        let stock = remainingStock(product.id)
        let outOfStock = stock == 0
        Button {
            onSelect(product.id)
        } label: {
            HStack(spacing: 12) {
                ProductImage(imagePath: product.imagePath, size: 36)
                    .opacity(outOfStock ? 0.45 : 1.0)
                Text(product.name ?? "Unnamed")
                    .foregroundStyle(outOfStock ? .secondary : .primary)
                if let stock {
                    stockPill(stock)
                }
                if let slots = existingSlotsByProduct[product.id], !slots.isEmpty {
                    Text(slotBadgeLabel(slots))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.orange.opacity(0.15)))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Already in \(slots.count == 1 ? "slot" : "slots") \(slots.sorted().map(String.init).joined(separator: ", "))")
                }
                Spacer()
                if selectedProductId == product.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
        }
        .id(product.id)
        .listRowBackground(
            highlightedProductId == product.id
                ? Color.accentColor.opacity(0.18)
                : Color.clear
        )
        .listRowSeparator(isLastInGroup ? .hidden : .visible, edges: .bottom)
    }
```

- [ ] **Step 6.4: Compile-check**

Run the standard build. Expected: `** BUILD SUCCEEDED **`.

If Xcode added `extractionState: "stale"` lines to `Localizable.xcstrings`, revert that file.

- [ ] **Step 6.5: Commit**

```bash
git add ios/VMflow/Views/Refill/ReviewStepView.swift
git commit -m "feat(refill): render grouped picker with stock and category headers"
```

---

### Task 7: Wire up the new picker parameters at the call site

**Files:**
- Modify: `ios/VMflow/Views/Refill/ReviewStepView.swift`

- [ ] **Step 7.1: Update the `.sheet(item:)` call site**

Find the `.sheet(item: $pickerTrayId) { trayId in ... ReplacementProductPicker(...) ... }` call site near the top of the file (around line 46). Update the `ReplacementProductPicker(...)` initializer to pass the new parameters between `remainingStock` and `onSelect`:

```swift
                ReplacementProductPicker(
                    products: viewModel.availableProducts,
                    selectedProductId: viewModel.replacements.first(where: { $0.trayId == trayId })?.replacementProductId,
                    existingSlotsByProduct: existingSlots(forTrayId: trayId),
                    machineLayout: machineLayout(forTrayId: trayId),
                    remainingStock: { id in
                        // Only show stock counts when a warehouse with stock
                        // data is loaded — otherwise we'd render bogus zeros.
                        guard viewModel.selectedWarehouseId != nil,
                              !viewModel.warehouseStock.isEmpty
                        else { return nil }
                        return viewModel.remainingWarehouseStock(productId: id)
                    },
                    currentCategoryId: viewModel.currentCategoryId(forTrayId: trayId),
                    categories: viewModel.productCategories,
                    onSelect: { productId in
                        viewModel.setReplacement(trayId: trayId, productId: productId)
                        pickerTrayId = nil
                    }
                )
```

- [ ] **Step 7.2: Compile-check**

Run the standard build. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7.3: Commit**

```bash
git add ios/VMflow/Views/Refill/ReviewStepView.swift
git commit -m "feat(refill): wire currentCategoryId and categories at picker call site"
```

---

### Task 8: Add a SwiftUI preview that exercises the grouped layout

**Files:**
- Modify: `ios/VMflow/Views/Refill/ReviewStepView.swift`

- [ ] **Step 8.1: Append the new preview**

At the very end of the file, after the existing `#Preview("Picker with grid (typical)")` block, append:

```swift
#Preview("Picker with grouping (typical)") {
    let snacksId = UUID()
    let drinksId = UUID()
    let sweetsId = UUID()

    let categories: [ProductCategory] = [
        ProductCategory(id: snacksId, name: "Snacks", company: UUID()),
        ProductCategory(id: drinksId, name: "Drinks", company: UUID()),
        ProductCategory(id: sweetsId, name: "Sweets", company: UUID()),
    ]

    let mars = Product(id: UUID(), name: "Mars",
                       imagePath: nil, discontinued: false, sellprice: 2.5,
                       category: snacksId)
    let bounty = Product(id: UUID(), name: "Bounty",
                         imagePath: nil, discontinued: false, sellprice: 2.5,
                         category: snacksId)
    let kitkat = Product(id: UUID(), name: "Kitkat",
                         imagePath: nil, discontinued: false, sellprice: 2.5,
                         category: snacksId)
    let twix = Product(id: UUID(), name: "Twix",
                       imagePath: nil, discontinued: false, sellprice: 2.5,
                       category: snacksId)
    let snickers = Product(id: UUID(), name: "Snickers",
                           imagePath: nil, discontinued: false, sellprice: 2.5,
                           category: snacksId)
    let fanta = Product(id: UUID(), name: "Fanta",
                        imagePath: nil, discontinued: false, sellprice: 2.5,
                        category: drinksId)
    let cola = Product(id: UUID(), name: "Cola",
                       imagePath: nil, discontinued: false, sellprice: 2.5,
                       category: drinksId)
    let gummy = Product(id: UUID(), name: "Gummy Bears",
                        imagePath: nil, discontinued: false, sellprice: 2.5,
                        category: sweetsId)

    let products = [mars, bounty, kitkat, twix, snickers, fanta, cola, gummy]

    // Stock map: snickers + fanta are out of stock.
    let stockMap: [UUID: Int] = [
        mars.id: 12,
        bounty.id: 15,
        kitkat.id: 4,
        twix.id: 8,
        snickers.id: 0,
        fanta.id: 0,
        cola.id: 10,
        gummy.id: 3,
    ]

    // Twix is already in slot 23, Cola in slot 31.
    let existing: [UUID: [Int]] = [
        twix.id: [23],
        cola.id: [31],
    ]

    return NavigationStack {
        ReplacementProductPicker(
            products: products,
            selectedProductId: nil,
            existingSlotsByProduct: existing,
            machineLayout: MachineGridLayout(rowCount: 0, columnsPerRow: 10, slots: []),
            remainingStock: { stockMap[$0] },
            currentCategoryId: snacksId,
            categories: categories,
            onSelect: { _ in }
        )
    }
}
```

- [ ] **Step 8.2: Compile-check**

Run the standard build. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8.3: Manually verify the preview**

Open `ReviewStepView.swift` in Xcode → canvas → select **"Picker with grouping (typical)"** preview. Verify:

- Section "IN STOCK" mega-header at the top, with count `6` on the right
- Below it, sub-header `SNACKS · CURRENT` in accent (blue) color
- Products in this order under Snacks: Bounty, Kitkat, Mars (alphabetical, none in machine), then Twix (in-machine, last)
- Sub-header `DRINKS` (secondary color)
- One product: Cola (in-machine, only Drinks in-stock product since Fanta is OOS)
- Sub-header `SWEETS`
- One product: Gummy Bears
- Mega-header "OUT OF STOCK" with count `2`
- Sub-header `SNACKS · CURRENT` (current still highlighted in OOS bucket)
- One product: Snickers (faded, grey "0 in stock" pill)
- Sub-header `DRINKS`
- One product: Fanta (faded)
- No visible separator lines between mega-header → sub-header → first row

If anything is off (wrong order, missing pills, visible spurious separators), inspect `stockBuckets` / `productRow` / `listRowSeparator(.hidden)` placement and fix.

- [ ] **Step 8.4: Commit**

```bash
git add ios/VMflow/Views/Refill/ReviewStepView.swift
git commit -m "test(refill): add grouped picker preview"
```

---

### Task 9: File-size check + final manual verification

**Files:**
- Maybe modify: extract `ReplacementProductPicker` into its own file.

- [ ] **Step 9.1: Measure final file size**

Run:
```bash
wc -l ios/VMflow/Views/Refill/ReviewStepView.swift
```

| Line count | Action |
|---|---|
| < 800 | Skip the extraction below. |
| ≥ 800 | Required. Extract `ReplacementProductPicker` into `ios/VMflow/Views/Refill/ReplacementProductPicker.swift`. (Matches the 800-line "must extract" threshold stated in the plan header.) |

- [ ] **Step 9.2: (Conditional) Extract picker into its own file**

Only if line count ≥ 800. Create `ios/VMflow/Views/Refill/ReplacementProductPicker.swift` and move into it:

- `extension UUID: @retroactive Identifiable` (only if not used elsewhere in the file — check first)
- `slotBadgeLabel(_:)` function
- `ReplacementProductPicker` struct (including its nested types `StockStatus`, `StockBucket`, `CategoryGroup`, `ProductSelection`, all `@State`, all computed properties, all helpers, and the `productRow` builder)
- Both picker previews (`"Picker with existing slots"`, `"Picker with grid (typical)"`, `"Picker with grouping (typical)"`)

Leave in `ReviewStepView.swift`:
- `ReviewStepView` struct (the wizard step view itself)
- All other helpers and state

Add `import SwiftUI` at the top of the new file. Run the standard build. If XcodeGen regeneration is needed (`project.yml` based — see Task 8 of the prior milestone), run `xcodegen` or let `xcodebuild` discover the file. Verify `** BUILD SUCCEEDED **`.

Commit:
```bash
git add ios/VMflow/Views/Refill/ReviewStepView.swift ios/VMflow/Views/Refill/ReplacementProductPicker.swift ios/VMflow.xcodeproj/project.pbxproj
git commit -m "refactor(refill): extract ReplacementProductPicker into its own file"
```

- [ ] **Step 9.3: Final on-device or simulator check**

Boot the app, navigate to the Refill wizard with a warehouse selected, walk through to the Review step, tap **Replace** on a tray with a current product. Verify on-device:

1. Mega-header "In Stock" at top with correct count
2. Current product's category appears first under "In Stock" with accent color + "· aktuell" / "· current" suffix
3. Within each category: products NOT already in the machine appear before products that ARE
4. Mega-header "Out of Stock" below "In Stock" if any product has 0 stock
5. Searching keeps the grouping (filtered set re-grouped)
6. With no warehouse selected (re-open from start without picking a warehouse): no mega-headers, only category sub-headers
7. German locale: headers read "AUF LAGER" / "NICHT AUF LAGER" / "OHNE KATEGORIE"

If any of these fail, fix and re-commit with a `fix(refill):` prefix.

---

## Final Verification Checklist

Before declaring the feature done:

- [ ] `xcodebuild build` succeeds on a clean build
- [ ] All four picker previews render without crashing in Xcode canvas
- [ ] Grouped preview matches the layout described in Task 8.3
- [ ] Manual on-device flow per Task 9.3 passes
- [ ] German strings render correctly when switching the simulator to DE
- [ ] No spurious `extractionState: "stale"` entries committed to `Localizable.xcstrings` (only the four new keys)

# iOS Refill Pack — Per-Machine Filter Chips Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a horizontal filter-chip leiste to the top of the iOS Refill wizard's Pack step that lets the operator focus the product list on a single machine ("one box per machine" workflow) while keeping today's combined product-centric view as the default `Alle` chip.

**Architecture:** Additive ViewModel layer (a `ChipFilter` enum, an `@Published var activeChip`, and a handful of derived computed properties) plus a SwiftUI refactor of `PackingStepView`: today's body is extracted into a private `AllPackingList` subview, a new `MachinePackingList` subview is added for the filtered case, and the body picks one based on `activeChip`. All existing packing actions (`togglePackedForMachine`, `setPackingQuantity`, `displayQuantity`, etc.) are reused — no function-signature changes, no data-model migration, no persistence changes.

**Tech Stack:** Swift 5.9, SwiftUI, iOS 17 deployment target, Xcode 16, `Localizable.xcstrings`.

**Spec:** [`docs/superpowers/specs/2026-05-26-ios-refill-per-machine-chips-design.md`](../specs/2026-05-26-ios-refill-per-machine-chips-design.md)

---

## File Map

**Modified files:**

- `ios/VMflow/ViewModels/RefillWizardViewModel.swift` — add `ChipFilter` enum (top-level), `@Published var activeChip`, computed properties `chipOrder` / `chipName(_:)` / `chipItemCount(_:)` / `chipIsFullyPacked(_:)` / `visibleItemsForActiveChip`, helper `packAllForMachine(_:)`, and the two reset hooks in `loadData()` and `refreshDuringPacking()`.
- `ios/VMflow/Views/Refill/PackingStepView.swift` — refactor `body` to split today's product list into a private `AllPackingList` subview, add new private subviews `ChipBar`, `HeaderStrip`, `MachinePackingList`, and switch between the two list subviews based on `viewModel.activeChip`.
- `ios/VMflow/Resources/Localizable.xcstrings` — eight new keys for chip / header strings, EN + DE.

**Intentionally NOT touched:**

- `ios/VMflow/Views/Refill/RefillWizardView.swift` — the chip lives inside `PackingStepView`; the wizard container has no awareness of it.
- `ios/VMflow/Views/Refill/ReviewStepView.swift`, `RefillStepView.swift`, `RefillSummaryView.swift` — other wizard steps are out of scope.
- `RefillWizardViewModel.PersistedTourState` — the Pack step is never persisted ([RefillWizardViewModel.swift:365](../../ios/VMflow/ViewModels/RefillWizardViewModel.swift#L365): `case .review, .packing: return`), so the chip is in-memory only by design.
- Any backend, PWA, or Android code.
- No new test target — the iOS project has no test bundle today (verified during spec review); adding one is out of scope.

---

## Prerequisites

- Xcode 16 with the project open: `ios/VMflow.xcodeproj` (or `open ios/VMflow.xcworkspace` if a workspace exists).
- iPhone simulator (iPhone 15 or newer recommended, iOS 17+).
- A working dev backend with at least 3 machines that have refillable trays, and a warehouse with stock for several products — so the chip leiste has enough machines to be visually interesting and so out-of-stock behavior can be exercised.
- Local Supabase running (`supabase start` in `Docker/supabase/`) if you want to drive real sales for the realtime UAT step.

**Verification before starting:**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git status               # working tree should be clean
git rev-parse HEAD       # note the SHA so you can compare diff scope at the end
```

---

## Chunk 1: ViewModel additions (no UI change)

This chunk extends the ViewModel only. After this chunk the app must still build and behave identically — no UI hook is wired yet.

### Task 1: Add `ChipFilter` enum and `activeChip` state

**Files:**
- Modify: `ios/VMflow/ViewModels/RefillWizardViewModel.swift`

**Rationale:** Pure additive types and state — the enum lives at file scope alongside the other refill data structures so other views could reference it later if needed.

- [ ] **Step 1: Add `ChipFilter` enum after `RefillStep`**

In `ios/VMflow/ViewModels/RefillWizardViewModel.swift`, find the `RefillStep` enum block ending at the `}` of `RefillStep`'s `icon` switch (around line 214). After that `}` (and before `// MARK: - ViewModel`), insert:

```swift
// MARK: - Pack Chip Filter

/// Filter chip selection in the Pack step. `.all` shows the full
/// product-centric combined list (today's behavior); `.machine(id)` filters
/// the list to just the products needed for that one machine. In-memory
/// only — not persisted in `PersistedTourState` because the Pack step
/// itself is never persisted.
enum ChipFilter: Equatable, Hashable {
    case all
    case machine(UUID)
}
```

- [ ] **Step 2: Add `activeChip` to the ViewModel's `@Published` block**

In `RefillWizardViewModel` find the existing `@Published` declarations (around lines 222–248). Add this line directly under `@Published var currentMachineIndex: Int = 0`:

```swift
/// Active filter chip in the Pack step. Resets to `.all` whenever
/// `loadData()` runs (fresh start). Snap-back to `.all` if the active
/// machine vanishes from `chipOrder` (defensive — shouldn't happen mid-tour).
@Published var activeChip: ChipFilter = .all
```

- [ ] **Step 3: Build to verify the enum compiles**

In Xcode: ⌘B (Build). Expected: no errors, no warnings related to `ChipFilter`.

- [ ] **Step 4: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add ios/VMflow/ViewModels/RefillWizardViewModel.swift
git commit -m "ios(refill): add ChipFilter enum and activeChip state"
```

---

### Task 2: Add chip-derived computed properties

**Files:**
- Modify: `ios/VMflow/ViewModels/RefillWizardViewModel.swift`

**Rationale:** Pure derivations from existing `machines` / `packedItems` / `combinedPackingList`. No side effects. They drive the chip leiste, header strip, and the filtered list.

- [ ] **Step 1: Add the chip helpers section**

Find the end of the `visibleCombinedPackingList` computed property (around line 553). After its closing `}`, insert the entire block below:

```swift
// MARK: - Chip Filter Helpers

/// Chips displayed in the Pack step, in order: `.all` first, then every
/// machine in `machines` order (matches the order surfaces in the rest of
/// the wizard).
var chipOrder: [ChipFilter] {
    [.all] + machines.map { .machine($0.id) }
}

/// Display name for a chip. `.all` uses the localized "All" label; a
/// machine chip uses the machine's `displayName`.
func chipName(_ chip: ChipFilter) -> String {
    switch chip {
    case .all:
        return String(localized: "All")
    case .machine(let id):
        return machines.first(where: { $0.id == id })?.machine.displayName ?? ""
    }
}

/// Potential box size for a chip — sum of `displayQuantity` over every
/// `(machine, product)` pair that has a need. For `.all` the sum is
/// across every machine; for `.machine(id)` only that one machine.
///
/// Intentionally distinct from `totalItemsToPack` (which only sums
/// across `packedMachines`). The chip shows "how big the box would be
/// if fully packed", the bottom bar shows "how many items the tour
/// will actually deliver".
func chipItemCount(_ chip: ChipFilter) -> Int {
    let allMachineIds: [UUID]
    switch chip {
    case .all:
        allMachineIds = machines.map(\.id)
    case .machine(let id):
        allMachineIds = [id]
    }
    var total = 0
    for item in combinedPackingList {
        for need in item.machineNeeds where allMachineIds.contains(need.machineId) {
            total += displayQuantity(machineId: need.machineId, productId: item.productId)
        }
    }
    return total
}

/// True when every needed `(machine, product)` pair for the chip is
/// both checked AND packed at the full required quantity. For `.all`
/// this requires every machine chip to be fully packed.
func chipIsFullyPacked(_ chip: ChipFilter) -> Bool {
    switch chip {
    case .all:
        let machineChips = chipOrder.dropFirst()
        guard !machineChips.isEmpty else { return false }
        return machineChips.allSatisfy(chipIsFullyPacked)
    case .machine(let id):
        var hadAnyNeed = false
        for item in combinedPackingList {
            guard let need = item.machineNeeds.first(where: { $0.machineId == id }) else { continue }
            hadAnyNeed = true
            let packed = isMachinePacked(machineId: id, productId: item.productId)
            guard packed else { return false }
            guard displayQuantity(machineId: id, productId: item.productId) >= need.quantity else { return false }
        }
        return hadAnyNeed
    }
}
```

- [ ] **Step 2: Build to verify**

In Xcode: ⌘B. Expected: no errors. (The new `"All"` localization key doesn't exist yet — `String(localized:)` falls back to the key string at runtime if the key is missing, so this still compiles. The key gets added in Chunk 2.)

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/ViewModels/RefillWizardViewModel.swift
git commit -m "ios(refill): add chip-derived computed helpers (order/name/count/done)"
```

---

### Task 3: Add `visibleItemsForActiveChip` list-shape switch

**Files:**
- Modify: `ios/VMflow/ViewModels/RefillWizardViewModel.swift`

**Rationale:** This is the single property the View reads to render the list — it returns the right shape depending on the active chip. For `.machine(id)` it rewrites each item so it carries only the one relevant `MachineNeed`, so the rendering code can ignore sub-rows and treat each card as a single-machine card.

- [ ] **Step 1: Append below the chip helpers from Task 2**

Append to `ios/VMflow/ViewModels/RefillWizardViewModel.swift` directly under the `chipIsFullyPacked` closing `}`:

```swift
/// Items to render in the Pack step's list, dispatched on `activeChip`.
///
/// - `.all`: passes through `visibleCombinedPackingList` unchanged (today's
///   behavior — product cards with expandable per-machine sub-rows).
/// - `.machine(id)`: filters and rewrites — each returned `CombinedPackingItem`
///   carries exactly one `MachineNeed` (the active machine's) and its
///   `totalQuantity` is that machine's deficit. The same "hide if out-of-
///   stock and nothing-packed-yet" rule as `visibleCombinedPackingList`
///   applies, scoped to this one machine.
var visibleItemsForActiveChip: [CombinedPackingItem] {
    switch activeChip {
    case .all:
        return visibleCombinedPackingList
    case .machine(let id):
        return combinedPackingList.compactMap { item in
            guard let need = item.machineNeeds.first(where: { $0.machineId == id }) else { return nil }
            let packed = isMachinePacked(machineId: id, productId: item.productId)
            let outOfStock = isOutOfStockForMachine(machineId: id, productId: item.productId)
            if outOfStock && !packed { return nil }
            return CombinedPackingItem(
                productId: item.productId,
                productName: item.productName,
                imagePath: item.imagePath,
                sellprice: item.sellprice,
                totalQuantity: need.quantity,
                machineNeeds: [need]
            )
        }
    }
}
```

- [ ] **Step 2: Build to verify**

In Xcode: ⌘B. Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/ViewModels/RefillWizardViewModel.swift
git commit -m "ios(refill): add visibleItemsForActiveChip list-shape switch"
```

---

### Task 4: Add `packAllForMachine` action helper

**Files:**
- Modify: `ios/VMflow/ViewModels/RefillWizardViewModel.swift`

**Rationale:** Mirrors `packAllMachines()` ([RefillWizardViewModel.swift:1368](../../ios/VMflow/ViewModels/RefillWizardViewModel.swift#L1368)) but scoped to one machine — drives the chip-aware "Select All" button. Reuses the same stock-aware skip rule.

- [ ] **Step 1: Add helper below `packAllMachines()`**

Find `packAllMachines()` (around line 1368 — search for `func packAllMachines`). After its closing `}`, insert:

```swift
/// Pack every product needed for one specific machine (stock-aware).
/// Mirrors `packAllMachines` but scoped — drives the "Pack all for %@"
/// button shown when the Pack step has a machine chip active.
///
/// Note: does NOT call `saveTourState()`. Consistent with the existing
/// pack-step helpers (`togglePackedForMachine`, `togglePackedAll`,
/// `packEverything`/`packAllMachines`) which also skip it. `saveTourState()`
/// is a no-op during `.packing` anyway (guard at line 361), but matching
/// the existing pattern keeps future maintenance simple.
func packAllForMachine(_ machineId: UUID) {
    for item in combinedPackingList {
        guard item.machineNeeds.contains(where: { $0.machineId == machineId }) else { continue }
        guard !isOutOfStockForMachine(machineId: machineId, productId: item.productId) else { continue }
        if !isMachinePacked(machineId: machineId, productId: item.productId) {
            togglePackedForMachine(productId: item.productId, machineId: machineId)
        }
    }
}
```

- [ ] **Step 2: Build to verify**

In Xcode: ⌘B. Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/ViewModels/RefillWizardViewModel.swift
git commit -m "ios(refill): add packAllForMachine helper for chip-scoped Select All"
```

---

### Task 5: Reset chip on `loadData()` and snap back on `refreshDuringPacking()`

**Files:**
- Modify: `ios/VMflow/ViewModels/RefillWizardViewModel.swift`

**Rationale:** Defensive resets — `loadData()` resets `activeChip` to `.all` at fresh start (matches the spec's "no persistence" decision). `refreshDuringPacking()` snaps back to `.all` if the active machine vanished from `machines` (cannot happen mid-tour today, but cheap belt-and-suspenders that avoids ever rendering a dangling chip).

- [ ] **Step 1: Find `loadData()` end and reset `activeChip`**

Search the file for `func loadData` (around line 970). Read the whole function — the success path is one `do { ... } catch { ... }` block ending around line 1110. Inside the `do` block there is exactly one `self.machines = ...` assignment (around line 995). Place this line **at the end of the `do` block, just before the closing `}` that precedes `catch`** — so the reset runs after `machines`, replacement detection, and the `currentStep` flip have all settled:

```swift
activeChip = .all
```

Sanity-check that there is only one assignment to `self.machines` inside `loadData()` itself:

```bash
grep -n "self\.machines = " /Users/lucienkerl/Development/mdb-esp32-cashless/ios/VMflow/ViewModels/RefillWizardViewModel.swift
```

(`resumeTour` at line ~339 and `refreshDuringPacking` at line ~840 also assign `machines = state.machines` / similar — those are intentionally NOT touched. `loadData` is the only fresh-start path.)

- [ ] **Step 2: Find `refreshDuringPacking()` end and add snap-back**

Search for `func refreshDuringPacking`. At the end of the function, before the closing `}`, insert:

```swift
// Snap-back: if the active machine vanished from chipOrder, drop to .all.
// Cannot happen in normal mid-tour flow, but cheap insurance against
// rendering a dangling chip selection.
if case .machine(let id) = activeChip, !machines.contains(where: { $0.id == id }) {
    activeChip = .all
}
```

- [ ] **Step 3: Build to verify**

In Xcode: ⌘B. Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add ios/VMflow/ViewModels/RefillWizardViewModel.swift
git commit -m "ios(refill): reset activeChip on loadData; snap back on machine-vanish"
```

---

### Task 6: Smoke-build to confirm Chunk 1 is sound

- [ ] **Step 1: Run the iOS app**

In Xcode: ⌘R. Launch on iPhone simulator. Sign in, navigate to **Refill → Pack** step.

- [ ] **Step 2: Confirm zero visible change**

Expected: the Pack step looks **exactly** as it did before. No chips, no header strip — the UI hasn't been wired yet. This is the desired state for Chunk 1.

- [ ] **Step 3: If anything looks different, stop and investigate**

If there is a visible regression, the ViewModel additions had a side effect. Check: did you accidentally reorder a `@Published` property in a way that re-encodes `PersistedTourState`? Did you add any side-effect into the new computed properties? Roll back to the previous commit and re-apply more carefully.

---

## Chunk 2: Localization

### Task 7: Add the chip / header localization keys (8 new + 1 verify)

**Files:**
- Modify: `ios/VMflow/Resources/Localizable.xcstrings`

**Rationale:** `Localizable.xcstrings` is JSON. The project convention (verified by grepping existing keys like `"Add %lld Trays"`, `"Capacity: %lld"`, `"%lldm ago"`) is **natural English strings used directly as keys, with `%lld`/`%@` format specifiers embedded**. There are zero dot-prefixed keys in the file today — match that convention.

**Critical Swift behavior:** `String(localized: "literal \(arg)")` does NOT look up the key `"literal"` — it looks up the key `"literal %lld"` (for `Int`) or `"literal %@"` (for `String`), generated by Swift converting each interpolation to its format specifier. So the xcstrings key must be the **fully-realized format string**, identical to what Swift will generate at the call site.

- [ ] **Step 1: Open the xcstrings file**

Open `ios/VMflow/Resources/Localizable.xcstrings` in Xcode (preferred — gives the table editor) or your text editor. Inspect an existing entry like `"Add %lld Trays"` so you have a concrete shape to mimic.

- [ ] **Step 2: Add the keys (8 new + 1 verify)**

Add the following entries to the top-level `"strings"` JSON object. The first 8 are new; the last one (`Select All`) already exists in xcstrings and is reused unchanged by `HeaderStrip` for `.all` mode — verify it's present, do not re-add or modify it. Each key is the **exact** lookup string Swift will generate from the corresponding call site (Task 10 / Task 11). If Xcode's table editor is used: click "+" to add each key, set English value, switch to German and set the German value, ensure state is "manual" (translated). If editing JSON directly, exact key spelling matters down to the `%lld` vs `%@` and the spacing.

| Key (also the EN value) | DE value |
| --- | --- |
| `All` | `Alle` |
| `All machines · %lld items · %lld/%lld ready` | `Alle Automaten · %lld Items · %lld/%lld ready` |
| `✓ All boxes packed · %lld items` | `✓ Alle Boxen komplett · %lld Items gepackt` |
| `%@ · Box: %lld items · %lld/%lld packed` | `%@ · Box: %lld Items · %lld/%lld gepackt` |
| `✓ %@ · Box complete · %lld/%lld packed` | `✓ %@ · Box komplett · %lld/%lld gepackt` |
| `⚠ %@ · new sale · box now %lld items (+%lld)` | `⚠ %@ · neuer Verkauf · Box jetzt %lld Items (+%lld)` |
| `Pack all for %@` | `%@ komplett packen` |
| `No products to pack for this machine` | `Keine Produkte für diesen Automaten zu packen` |
| `Select All` | (already exists — verify only; do NOT modify) |

**Format-specifier rules:**
- `%lld` for any Swift `Int` argument (Foundation bridges `Int` to `CLong` → `%ld` on 32-bit, `%lld` on 64-bit; `%lld` is safe for both, and is what Swift's localization tooling emits).
- `%@` for any Swift `String` argument.
- The order of `%`-placeholders in the key must match the order of `\(...)` interpolations in the Swift call site, exactly.

`String(localized:)` is an **initializer**, not a macro — there is no `#localized` macro to look for.

- [ ] **Step 3: Build to verify the JSON is well-formed**

In Xcode: ⌘B. Expected: no errors. If Xcode shows "string catalog corrupted" or similar, re-open in a text editor and check for a misplaced comma or unmatched brace.

- [ ] **Step 4: Commit**

```bash
git add ios/VMflow/Resources/Localizable.xcstrings
git commit -m "ios(refill): add localization keys for Pack chips (EN+DE)"
```

---

## Chunk 3: View refactor — extract `AllPackingList` without behavior change

### Task 8: Extract today's body into a private `AllPackingList` subview

**Files:**
- Modify: `ios/VMflow/Views/Refill/PackingStepView.swift`

**Rationale:** Before adding any new UI, pull today's `productCard`/`summaryHeader`/`emptyState`/list-rendering code into a focused subview. This means Chunk 4 only adds NEW code (chip bar, header strip, machine list) — it doesn't have to also fight the giant body. After this task the app behaves identically to before.

- [ ] **Step 1: Skim the file to memorise the moving parts**

Open `ios/VMflow/Views/Refill/PackingStepView.swift`. The current `body` calls (in order):
- `warehousePicker`
- `summaryHeader`
- `emptyState` OR `ForEach(viewModel.visibleCombinedPackingList) { item in productCard(item) }`
- `bottomBar`

The `productCard(_:)` helper is the big one (lines 106–260 in the current file) and uses `machineNeedRow(item:need:)` (lines 264–375).

- [ ] **Step 2: Add `AllPackingList` as a private struct at the bottom of the file**

At the very bottom of `PackingStepView.swift` (after `#Preview`), add the new struct. Move three things into it: `summaryHeader`, `productCard(_:)`, `machineNeedRow(item:need:)`, `emptyState`, and `warehouseStockBadge(for:)`. Pass any required references via stored properties.

Add this exact scaffold first, then move the methods into it one by one:

```swift
// MARK: - AllPackingList Subview

/// Today's product-centric list — extracted unchanged from PackingStepView.
/// Renders cards grouped by product with expandable per-machine sub-rows.
/// Used when the active chip is `.all`.
private struct AllPackingList: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    @Binding var selectedProduct: PackingStepView.ProductSelection?

    var body: some View {
        VStack(spacing: 12) {
            summaryHeader
            if viewModel.visibleCombinedPackingList.isEmpty && !viewModel.isLoading {
                emptyState
            } else {
                ForEach(viewModel.visibleCombinedPackingList) { item in
                    productCard(item)
                }
            }
        }
    }

    // (move summaryHeader, productCard, machineNeedRow, warehouseStockBadge, emptyState here)
}
```

- [ ] **Step 3: Move the five helpers from `PackingStepView` into `AllPackingList`**

Cut these five blocks out of `PackingStepView` and paste them as members of `AllPackingList`:

- `private var summaryHeader: some View` (lines 81–102 in the current file)
- `private func productCard(_ item: CombinedPackingItem) -> some View` (lines 106–260)
- `private func machineNeedRow(item: CombinedPackingItem, need: MachineNeed) -> some View` (lines 264–375)
- `@ViewBuilder private func warehouseStockBadge(for item: CombinedPackingItem) -> some View` (lines 379–420)
- `private var emptyState: some View` (lines 424–436)

The `selectedProduct` callsite inside `productCard` (currently `selectedProduct = ProductSelection(...)`) needs to refer to the binding — change `selectedProduct = ProductSelection(...)` to `selectedProduct = PackingStepView.ProductSelection(...)` since `ProductSelection` is nested in `PackingStepView`.

Make `PackingStepView.ProductSelection` non-private so the new struct can reach it. In `PackingStepView`, change:

```swift
struct ProductSelection: Identifiable {
```

to:

```swift
fileprivate struct ProductSelection: Identifiable {
```

(`fileprivate` is the right visibility — both structs share the file.)

- [ ] **Step 4: Update `PackingStepView.body` to call `AllPackingList`**

The current `body`'s `ScrollView { VStack { ... } }` should become:

```swift
ScrollView {
    VStack(spacing: 12) {
        if !viewModel.warehouses.isEmpty {
            warehousePicker
        }
        AllPackingList(viewModel: viewModel, selectedProduct: $selectedProduct)
    }
    .padding(.horizontal)
    .padding(.bottom, 100)
}
```

Keep `warehousePicker` and `bottomBar` on `PackingStepView` for now — they don't move.

- [ ] **Step 5: Build**

In Xcode: ⌘B. Fix any compile errors — most likely candidates: missing `selectedProduct` binding wiring, missing `ProductSelection` visibility, an undefined symbol that needs `viewModel.` prefix.

- [ ] **Step 6: Run and manually verify ZERO behavior change**

⌘R. Navigate to Refill → Pack. Compare against the screenshot you took at Task 6 (or against memory of the original UI). All of these must still work:

1. Empty state renders when nothing needs refill.
2. Product cards render in the same order, with the same badges (warehouse stock, sellprice, totals).
3. Round product checkbox ticks/unticks all machines for that product.
4. Square per-machine sub-row checkbox ticks just that one machine.
5. Stepper +/- adjusts the per-machine quantity, the product card's total updates live.
6. Tapping the `info.circle` opens the `ProductDetailSheet`.
7. The "Select All" button at the top right of the list still selects all products for all machines.
8. The bottom bar's "Start Tour" button transitions to the Refill step when at least one machine is packed.

If any of these regress, the cut-and-paste introduced a wiring error. Roll back to Chunk 1's last commit and redo this task more carefully.

- [ ] **Step 7: Commit**

```bash
git add ios/VMflow/Views/Refill/PackingStepView.swift
git commit -m "ios(refill): extract AllPackingList subview (no behavior change)"
```

---

## Chunk 4: New UI — chip bar, header strip, machine list

### Task 9: Add the `ChipBar` private subview

**Files:**
- Modify: `ios/VMflow/Views/Refill/PackingStepView.swift`

**Rationale:** Horizontal scrolling pill leiste. Visual states: inactive / active / done / active+done. Tapping sets `viewModel.activeChip`. Wrapping the chip-press in a `withAnimation` keeps the list-shape switch smooth.

- [ ] **Step 1: Add `ChipBar` at the bottom of the file (after `AllPackingList`)**

```swift
// MARK: - ChipBar Subview

private struct ChipBar: View {
    @ObservedObject var viewModel: RefillWizardViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.chipOrder, id: \.self) { chip in
                    chipPill(chip)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    private func chipPill(_ chip: ChipFilter) -> some View {
        let isActive = viewModel.activeChip == chip
        let isDone = viewModel.chipIsFullyPacked(chip)
        let name = viewModel.chipName(chip)
        let count = viewModel.chipItemCount(chip)

        let bg: Color = {
            if isActive && isDone { return .green }
            if isActive { return .accentColor }
            if isDone { return Color.green.opacity(0.15) }
            return Color(.secondarySystemGroupedBackground)
        }()
        let fg: Color = {
            if isActive { return .white }
            if isDone { return .green }
            return .primary
        }()

        return Button {
            HapticFeedback.light.fire()
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.activeChip = chip
            }
        } label: {
            HStack(spacing: 4) {
                Text(name)
                    .font(.caption.weight(isActive ? .semibold : .regular))
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                } else {
                    Text(" · \(count)")
                        .font(.caption2)
                        .opacity(0.7)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(bg))
            .foregroundStyle(fg)
            .overlay(Capsule().stroke(.black.opacity(0.06), lineWidth: 0.5))
            .shadow(color: .black.opacity(isActive ? 0.15 : 0.05), radius: isActive ? 4 : 2, y: 1)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Build**

⌘B. Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/Views/Refill/PackingStepView.swift
git commit -m "ios(refill): add ChipBar subview (not yet wired into body)"
```

---

### Task 10: Add the `HeaderStrip` private subview

**Files:**
- Modify: `ios/VMflow/Views/Refill/PackingStepView.swift`

**Rationale:** Replaces today's `summaryHeader` (which moved into `AllPackingList`). Renders the chip-aware status banner and houses the chip-aware "Select All" button. Three colors: blue (pending), green (done), orange (sale-after-pack — detected by `chipIsFullyPacked == false` but `totalPackedForChip > 0`).

- [ ] **Step 1: Add `HeaderStrip` at the bottom of the file**

```swift
// MARK: - HeaderStrip Subview

private struct HeaderStrip: View {
    @ObservedObject var viewModel: RefillWizardViewModel

    var body: some View {
        HStack(spacing: 10) {
            Text(headerText)
                .font(.footnote.weight(.medium))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                HapticFeedback.light.fire()
                switch viewModel.activeChip {
                case .all:
                    viewModel.packAllMachines()
                case .machine(let id):
                    viewModel.packAllForMachine(id)
                }
            } label: {
                Text(selectAllLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(foreground)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(background))
        .animation(.easeInOut(duration: 0.2), value: viewModel.activeChip)
    }

    // MARK: derived

    private enum HeaderState { case pending, done, alert }

    private var state: HeaderState {
        switch viewModel.activeChip {
        case .all:
            return viewModel.chipIsFullyPacked(.all) ? .done : .pending
        case .machine(let id):
            let done = viewModel.chipIsFullyPacked(.machine(id))
            if done { return .done }
            // Alert = at least one product is packed for this machine but the
            // overall chip is no longer fully packed (a sale increased deficit
            // since pack time).
            let anyPacked = viewModel.combinedPackingList.contains { item in
                item.machineNeeds.contains(where: { $0.machineId == id })
                    && viewModel.isMachinePacked(machineId: id, productId: item.productId)
            }
            return anyPacked ? .alert : .pending
        }
    }

    private var background: Color {
        switch state {
        case .pending: return Color.blue.opacity(0.10)
        case .done:    return Color.green.opacity(0.14)
        case .alert:   return Color.orange.opacity(0.14)
        }
    }

    private var foreground: Color {
        switch state {
        case .pending: return Color.blue
        case .done:    return Color.green
        case .alert:   return Color.orange
        }
    }

    private var headerText: String {
        switch viewModel.activeChip {
        case .all:
            let total = viewModel.chipItemCount(.all)
            if state == .done {
                return String(localized: "✓ All boxes packed · \(total) items")
            } else {
                let ready = viewModel.packedMachines.count
                let totalM = viewModel.machines.count
                return String(localized: "All machines · \(total) items · \(ready)/\(totalM) ready")
            }
        case .machine(let id):
            let name = viewModel.chipName(.machine(id))
            let total = viewModel.chipItemCount(.machine(id))
            let needs = viewModel.combinedPackingList.compactMap { item -> (UUID, Int)? in
                guard let n = item.machineNeeds.first(where: { $0.machineId == id }) else { return nil }
                return (item.productId, n.quantity)
            }
            let packed = needs.filter { viewModel.isMachinePacked(machineId: id, productId: $0.0) }.count
            switch state {
            case .done:    return String(localized: "✓ \(name) · Box complete · \(packed)/\(needs.count) packed")
            case .alert:
                // Compute the delta — current "needed beyond packed" sum
                let extra = needs.reduce(0) { sum, pair in
                    let (pid, qty) = pair
                    guard viewModel.isMachinePacked(machineId: id, productId: pid) else { return sum }
                    let packedQty = viewModel.displayQuantity(machineId: id, productId: pid)
                    return sum + max(0, qty - packedQty)
                }
                return String(localized: "⚠ \(name) · new sale · box now \(total) items (+\(extra))")
            case .pending: return String(localized: "\(name) · Box: \(total) items · \(packed)/\(needs.count) packed")
            }
        }
    }

    private var selectAllLabel: String {
        switch viewModel.activeChip {
        case .all:
            return String(localized: "Select All")
        case .machine(let id):
            let name = viewModel.chipName(.machine(id))
            return String(localized: "Pack all for \(name)")
        }
    }
}
```

- [ ] **Step 2: Build**

⌘B. Expected: no errors. Localization-key resolution at runtime falls back to the key string if any of the new keys are missing — but you added them in Chunk 2, so they should resolve.

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/Views/Refill/PackingStepView.swift
git commit -m "ios(refill): add HeaderStrip subview with chip-aware status + Select All"
```

---

### Task 11: Add the `MachinePackingList` private subview

**Files:**
- Modify: `ios/VMflow/Views/Refill/PackingStepView.swift`

**Rationale:** Flat per-product cards for the filtered case. Each card is a single-machine commitment — round checkbox toggles `(machine, product)`, stepper adjusts that pair's quantity, "Partial" / "No stock" badges follow the existing per-machine rules. Border color mirrors the existing rules: green when fully packed, orange when partial. Visual style intentionally close to today's `machineNeedRow` to stay familiar.

- [ ] **Step 1: Add `MachinePackingList` at the bottom of the file**

```swift
// MARK: - MachinePackingList Subview

/// Flat per-product list scoped to one machine — used when the active chip
/// is `.machine(id)`. Each card commits / adjusts the `(machineId, productId)`
/// pair via the same ViewModel functions the `.all` view uses, so packed
/// state stays in sync across both views.
private struct MachinePackingList: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    let machineId: UUID
    @Binding var selectedProduct: PackingStepView.ProductSelection?

    var body: some View {
        if viewModel.visibleItemsForActiveChip.isEmpty {
            emptyState
        } else {
            VStack(spacing: 12) {
                ForEach(viewModel.visibleItemsForActiveChip) { item in
                    card(item)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text(String(localized: "No products to pack for this machine"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func card(_ item: CombinedPackingItem) -> some View {
        // By construction visibleItemsForActiveChip always returns items
        // with exactly one MachineNeed for the active machine.
        let need = item.machineNeeds[0]
        let isPacked = viewModel.isMachinePacked(machineId: machineId, productId: item.productId)
        let isDisabled = viewModel.isOutOfStockForMachine(machineId: machineId, productId: item.productId)
        let qty = viewModel.displayQuantity(machineId: machineId, productId: item.productId)
        let maxQty = viewModel.maxPackingQuantity(machineId: machineId, productId: item.productId)
        let isFullyPacked = isPacked && qty >= need.quantity
        let isPartial = isPacked && qty < need.quantity

        let borderColor: Color = {
            if isDisabled { return .clear }
            if isFullyPacked { return .green.opacity(0.35) }
            if isPartial { return .orange.opacity(0.55) }
            return .clear
        }()
        let borderWidth: CGFloat = isPartial ? 2 : 1.5

        return HStack(spacing: 12) {
            Button {
                guard !isDisabled else { return }
                HapticFeedback.light.fire()
                viewModel.togglePackedForMachine(productId: item.productId, machineId: machineId)
            } label: {
                Image(systemName: isDisabled ? "xmark.circle.fill" :
                        (isFullyPacked ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(isDisabled ? .red.opacity(0.5) :
                                    (isFullyPacked ? .green : .secondary))
            }
            .buttonStyle(.borderless)
            .disabled(isDisabled)

            ProductImage(imagePath: item.imagePath, size: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.productName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("needs \(need.quantity) / \(need.capacity)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let price = item.formattedSellprice {
                        Text(price)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if isDisabled {
                        Text("No stock")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.red)
                    } else if isPartial {
                        Text("Partial")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Button {
                selectedProduct = PackingStepView.ProductSelection(
                    id: item.productId,
                    name: item.productName,
                    imagePath: item.imagePath,
                    sellprice: item.sellprice
                )
            } label: {
                Image(systemName: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Spacer()

            HStack(spacing: 6) {
                Button {
                    HapticFeedback.light.fire()
                    viewModel.setPackingQuantity(machineId: machineId, productId: item.productId, quantity: qty - 1)
                } label: {
                    Image(systemName: "minus")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 10).stroke(Color(.systemGray3), lineWidth: 1.5))
                        .foregroundStyle(qty > 0 ? .primary : .quaternary)
                }
                .disabled(qty <= 0 || isDisabled)

                Text("\(qty)")
                    .font(.body.weight(.bold))
                    .monospacedDigit()
                    .frame(minWidth: 36, minHeight: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(isDisabled ? Color.gray.opacity(0.1) : Color.blue.opacity(0.1)))
                    .foregroundStyle(isDisabled ? Color.secondary : Color.blue)

                Button {
                    HapticFeedback.light.fire()
                    viewModel.setPackingQuantity(machineId: machineId, productId: item.productId, quantity: qty + 1)
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 10).stroke(Color(.systemGray3), lineWidth: 1.5))
                        .foregroundStyle(qty < maxQty && !isDisabled ? .primary : .quaternary)
                }
                .disabled(qty >= maxQty || isDisabled)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor, lineWidth: borderWidth))
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
        .opacity(isDisabled ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isFullyPacked)
        .animation(.easeInOut(duration: 0.2), value: isPartial)
    }
}
```

- [ ] **Step 2: Build**

⌘B. Expected: no errors. `ProductImage` and `HapticFeedback` should resolve from existing imports / project scope (they're already used in `AllPackingList`).

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/Views/Refill/PackingStepView.swift
git commit -m "ios(refill): add MachinePackingList subview for filtered chip mode"
```

---

### Task 12: Wire `ChipBar`, `HeaderStrip`, and the list-switch into `body`

**Files:**
- Modify: `ios/VMflow/Views/Refill/PackingStepView.swift`

**Rationale:** Final wiring. After this, the feature is functional end-to-end.

- [ ] **Step 1: Update `PackingStepView.body`**

Replace the `ScrollView { VStack { ... } }` block from Task 8 with this:

```swift
ScrollView {
    VStack(spacing: 12) {
        if !viewModel.warehouses.isEmpty {
            warehousePicker
        }
        ChipBar(viewModel: viewModel)
        HeaderStrip(viewModel: viewModel)

        Group {
            switch viewModel.activeChip {
            case .all:
                AllPackingList(viewModel: viewModel, selectedProduct: $selectedProduct)
            case .machine(let id):
                MachinePackingList(viewModel: viewModel, machineId: id, selectedProduct: $selectedProduct)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.activeChip)
    }
    .padding(.horizontal)
    .padding(.bottom, 100)
}
```

- [ ] **Step 2: Remove the old `summaryHeader` call from inside `AllPackingList`**

`AllPackingList.body` (Task 8) called `summaryHeader` at the top. The chip's `HeaderStrip` now replaces it for both views. Edit `AllPackingList.body` to drop the `summaryHeader` invocation:

```swift
var body: some View {
    VStack(spacing: 12) {
        if viewModel.visibleCombinedPackingList.isEmpty && !viewModel.isLoading {
            emptyState
        } else {
            ForEach(viewModel.visibleCombinedPackingList) { item in
                productCard(item)
            }
        }
    }
}
```

`summaryHeader` itself stays on the struct as dead code for one commit (so the diff stays small), then gets deleted in Task 13.

- [ ] **Step 3: Build**

⌘B. Expected: no errors. **Expected warning**: Xcode will likely flag `summaryHeader` as an unused property — that's intentional for this commit, Task 13 deletes it. Don't suppress the warning.

- [ ] **Step 4: Commit**

```bash
git add ios/VMflow/Views/Refill/PackingStepView.swift
git commit -m "ios(refill): wire ChipBar + HeaderStrip + list-switch into Pack body"
```

---

### Task 13: Delete the now-dead `summaryHeader`

**Files:**
- Modify: `ios/VMflow/Views/Refill/PackingStepView.swift`

**Rationale:** Cleanup. `summaryHeader` is unreachable after Task 12. (Note: the `"Select All"` localization key is still used in `HeaderStrip.selectAllLabel` for `.all` mode — do NOT remove that key from xcstrings.)

- [ ] **Step 1: Verify `summaryHeader` is truly unused**

```bash
grep -n "summaryHeader" /Users/lucienkerl/Development/mdb-esp32-cashless/ios/VMflow/Views/Refill/PackingStepView.swift
```

Expected output: only the property declaration (no call sites).

- [ ] **Step 2: Delete the `summaryHeader` property from `AllPackingList`**

Remove the entire `private var summaryHeader: some View { ... }` block.

- [ ] **Step 3: Build**

⌘B. Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add ios/VMflow/Views/Refill/PackingStepView.swift
git commit -m "ios(refill): drop dead summaryHeader (superseded by HeaderStrip)"
```

---

## Chunk 5: UAT and polish

### Task 14: End-to-end manual UAT

**Files:** None — runtime verification.

**Rationale:** Confirm every spec scenario behaves as designed. If a step fails, capture the symptom and decide whether the cause is in the View (Tasks 8–12), ViewModel (Tasks 1–5), or localization (Task 7) before fixing.

- [ ] **Step 1: Open the app on a simulator with rich test data**

⌘R. Sign in. Navigate to Refill → Pack. Confirm the warehouse picker, chip leiste (with `Alle` selected by default), header strip (blue, "Alle Automaten · N Items · 0/M ready"), and the existing product cards all render.

- [ ] **Step 2: Default chip**

Confirm `Alle` is the active chip on first entry. Confirm the list shape matches today's product-centric view with sub-rows.

- [ ] **Step 3: Tap a machine chip**

Tap a machine chip (e.g. "Foyer · 23"). Confirm:
- The chip becomes blue/active with white text.
- Header strip flips to "Foyer Eingang · Box: 23 Items · 0/N packed".
- The list switches to flat single-machine cards (no sub-rows), each card showing this machine's deficit and a quantity stepper.
- Quantities collapse to that one machine's needs.

- [ ] **Step 4: Tap back to `Alle`**

Tap `Alle`. Confirm the original combined view returns with all sub-rows intact and any prior tick survives.

- [ ] **Step 5: Pack a full box from a single chip**

With a machine chip active, tap the round checkbox on each product card until all are packed. Confirm:
- Each card gains a green border.
- The chip turns green with a ✓.
- The header strip turns green ("✓ Foyer Eingang · Box komplett · N/N packed").
- **The cards remain visible and editable.**

- [ ] **Step 6: Untick one packed product**

Tap a packed product's round checkbox. Confirm:
- That card loses its green border.
- The chip's ✓ disappears, the count returns.
- The header strip returns to "pending" blue.

- [ ] **Step 7: Test "Select All" in chip-mode**

Re-tick everything via the `Pack all for %@` button in the header strip. Confirm all products tick in one shot, chip turns green.

- [ ] **Step 8: Stepper manipulation**

Pick a packed product, tap `−` until quantity < need. Confirm:
- Card gains orange border with "Partial" badge.
- Chip's ✓ disappears.
- Header strip turns to pending state.

- [ ] **Step 9: Realtime sale (if backend reachable)**

While the chip's machine is fully packed, trigger a sale on a product in that machine from the backend (Supabase Studio: insert into `sales`). Wait ~1 second. Confirm:
- The relevant card gains a "Partial" badge and orange border.
- Chip's ✓ disappears, count updates.
- Header strip turns orange with "neuer Verkauf · Box jetzt N items (+M)".
- Tapping `+` on the stepper to cover the delta restores green.

- [ ] **Step 10: Multi-chip done state**

Pack all machines. Confirm:
- Every machine chip is green with ✓.
- `Alle` chip is green with ✓.
- Header strip is green ("✓ Alle Boxen komplett · N Items gepackt").
- Bottom bar's "Start Tour" button is enabled.

- [ ] **Step 11: Warehouse change**

With at least one chip active and some products packed, change the warehouse via the picker at the top. Confirm:
- Chip counts re-derive (some chips may show different counts based on warehouse cap).
- Active chip stays selected.
- Already-packed items retain their tick if still fillable; cards may switch to "Partial" if the new warehouse has less stock.

- [ ] **Step 12: Step navigation**

Start the tour, then return to Pack via the step indicator (`canNavigateTo(.packing)` returns `true` from `.refill`, see `RefillWizardView.swift:125`). Confirm `activeChip` is `.all` again on re-entry (no persistence is the intended behavior).

- [ ] **Step 13: Resume tour**

Kill the app while in the Refill step. Re-open. Choose "Resume". Confirm: lands on the Refill step (not Pack), the chip never gets a chance to surface. This is correct — `PersistedTourState` saves from `.refill` onward only.

- [ ] **Step 14: If any of the above fail, fix and re-run**

For each failure, identify the layer:
- Wrong chip count → check `chipItemCount` math in `RefillWizardViewModel`.
- Wrong header text → check `HeaderStrip.headerText` switch or the localization key.
- Wrong chip styling → check the color/style switches in `ChipBar.chipPill`.
- Wrong list shape → check `visibleItemsForActiveChip` in `RefillWizardViewModel`.

Re-build and re-run after each fix. Commit fixes as discovered:

```bash
git add ...
git commit -m "ios(refill): fix <symptom>"
```

---

### Task 15: Locale switch — German UAT

**Files:** None — runtime verification.

- [ ] **Step 1: Set the simulator to German**

iOS Settings → General → Language & Region → iPhone Language → Deutsch. Restart the app.

- [ ] **Step 2: Re-walk Tasks 14 steps 1–10**

Confirm all chip labels, the header strip text, and the "Select All" button read in German per the localization table from Task 7. Pay attention to placeholder ordering (`%@`/`%lld`) — if any string reads garbled, fix the key in `Localizable.xcstrings`.

- [ ] **Step 3: Switch back to English**

Verify nothing regresses in English mode.

- [ ] **Step 4: Commit any fixes**

```bash
git add ios/VMflow/Resources/Localizable.xcstrings
git commit -m "ios(refill): fix German placeholder ordering in <key>"
```

---

### Task 16: Final diff review

- [ ] **Step 1: Review the cumulative diff**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git log --oneline <starting-sha-noted-in-prerequisites>..HEAD
git diff <starting-sha>..HEAD --stat
```

Confirm:
- Three files touched: `RefillWizardViewModel.swift`, `PackingStepView.swift`, `Localizable.xcstrings`.
- VM: ~50–65 net-new lines.
- View: ~150–200 net-new lines, **plus ~330 lines of move-only churn from the Task 8 `AllPackingList` extraction** (deleted from the original location, re-added inside the new private struct). `git diff --stat` will overstate the view change because of this — sanity-check by reading the diff rather than just trusting the number.
- `Localizable.xcstrings`: 8 new entries (the 9th — `Refill Tour` — already existed).
- No accidental edits to other Refill files (Review/Refill/Summary/Wizard).

- [ ] **Step 2: Run SwiftLint if configured**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
swiftlint lint VMflow/Views/Refill/PackingStepView.swift VMflow/ViewModels/RefillWizardViewModel.swift 2>/dev/null || echo "swiftlint not configured — skip"
```

Fix any warnings flagged in the new code (don't touch unrelated pre-existing warnings).

- [ ] **Step 3: Final commit if any lint fixes were made**

```bash
git add ios/VMflow/Views/Refill/PackingStepView.swift ios/VMflow/ViewModels/RefillWizardViewModel.swift
git commit -m "ios(refill): swiftlint cleanup for chip subviews"
```

---

## Done

Plan is complete when:

1. All Chunk-1 through Chunk-5 tasks are checked off.
2. The simulator UAT in Task 14 passes end-to-end without rollback.
3. The German UAT in Task 15 passes.
4. The git log shows a clean linear series of focused commits (one per task), and the diff scope matches the spec's File Map.

The feature can then be opened for review (PR or direct merge depending on the repo's convention) — link both the spec and this plan in the PR description.

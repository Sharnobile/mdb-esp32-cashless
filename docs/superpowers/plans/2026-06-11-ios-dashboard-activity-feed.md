# iOS Dashboard "Letzte Aktivität" Feed Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the iOS dashboard's "Recent Sales" section into a merged "Recent Activity" feed (sales + machine refills + grouped stock intakes + new tour-started events) with infinite scroll replacing the "Load more" button; both clients (iOS + PWA) start writing a `tour_started` activity event and stamp the `tour_id` into warehouse-deduction metadata.

**Spec:** `docs/superpowers/specs/2026-06-11-ios-dashboard-activity-feed-design.md` (read it first; it is the authority on behavior).

**Architecture:** Client-side merge of three sources (sales table, `activity_log` rows with actions `stock_refill_tour`/`tour_started`, `warehouse_transactions` rows with `transaction_type='incoming'` grouped into ≤15-min sessions) into one `[ActivityFeedItem]` timeline in `DashboardViewModel`. No DB migration; all writes are additive (new action string, new jsonb metadata keys).

**Tech Stack:** SwiftUI + supabase-swift v2 (iOS, no test target — verify by building), Nuxt 4 + Vitest (PWA), PostgREST joins, Supabase Realtime (version-counter pattern).

**Important project rules:**
- NEVER run `supabase db reset`. (No migrations are needed for this feature anyway.)
- Do not use git worktrees. Work on the current branch.
- Commit with explicit paths (`git commit -m "..." -- <paths>`); another agent session may commit to the same branch concurrently. Never amend/rebase commits you did not make in this session.
- `ios/VMflow/Resources/Localizable.xcstrings`, `ios/VMflow/Views/Machines/MachineDetailView.swift`, and other files have **uncommitted changes from other work**. Only stage the files this plan touches, and within `Localizable.xcstrings` make purely additive edits.

**Build commands used throughout:**

```bash
# iOS build (from repo root). If 'generic/platform=iOS Simulator' is rejected,
# list simulators with: xcrun simctl list devices available | head -20
# and use -destination 'platform=iOS Simulator,name=<an available iPhone>'
xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO -quiet build

# PWA tests (from management-frontend/)
npx vitest run
```

---

## Chunk 1: PWA — `tour_started` writer + tour_id linkage

### Task 1: Pure payload builder `buildTourStartedEntry` (TDD)

**Files:**
- Modify: `management-frontend/app/composables/useRefillWizard.ts` (add exported pure function near the top, after the existing interface declarations, before `export function useRefillWizard()`)
- Test (create): `management-frontend/app/composables/__tests__/useRefillWizard.tourStarted.test.ts`

The builder is a pure function so it can be unit-tested without the composable's Nuxt context. It produces the exact `activity_log` insert payload defined in spec §3.1.

- [ ] **Step 1: Write the failing test**

Create `management-frontend/app/composables/__tests__/useRefillWizard.tourStarted.test.ts`. The global-stub preamble mirrors `useDeals.keywords.test.ts` (useRefillWizard.ts relies on Nuxt auto-imports as bare globals at call time; stubs must exist before the module import evaluates):

```ts
import { describe, it, expect } from 'vitest'
import { ref as vueRef, computed as vueComputed } from 'vue'

// useRefillWizard.ts uses Nuxt auto-imports (`ref`, `computed`, `useState`)
// as bare globals (its `useSupabaseClient` import resolves via the vitest
// `#imports` alias). Expose the globals before the module import evaluates.
// Mirrors useDeals.keywords.test.ts / useWarehouse.test.ts.
;(globalThis as any).ref = vueRef
;(globalThis as any).computed = vueComputed
;(globalThis as any).useState = <T,>(_k: string, init?: () => T) => vueRef(init ? init() : undefined)
;(globalThis as any).useSupabaseClient = () => ({ from: () => ({}) })
;(globalThis as any).useSupabaseUser = () => vueRef({ id: 'user-1' })
;(globalThis as any).useOrganization = () => ({ organization: vueRef({ id: 'company-1' }) })

import { buildTourStartedEntry } from '../useRefillWizard'

describe('buildTourStartedEntry', () => {
  const machines = [
    { id: 'm-1', name: 'Automat Bahnhof' },
    { id: 'm-2', name: 'Automat Schule' },
  ]

  it('builds the full activity_log payload', () => {
    const entry = buildTourStartedEntry({
      companyId: 'company-1',
      user: {
        id: 'user-1',
        email: 'max@example.com',
        user_metadata: { first_name: 'Max', last_name: 'Muster' },
      },
      tourId: 'tour-123',
      machines,
      warehouseId: 'wh-1',
      warehouseName: 'Hauptlager',
    })

    expect(entry).toEqual({
      company_id: 'company-1',
      user_id: 'user-1',
      entity_type: 'stock',
      entity_id: 'tour-123',
      action: 'tour_started',
      metadata: {
        tour_id: 'tour-123',
        machine_count: 2,
        machine_ids: ['m-1', 'm-2'],
        machine_names: ['Automat Bahnhof', 'Automat Schule'],
        warehouse_id: 'wh-1',
        warehouse_name: 'Hauptlager',
        _user_email: 'max@example.com',
        _user_display: 'Max Muster',
      },
    })
  })

  it('falls back to email when no name is set', () => {
    const entry = buildTourStartedEntry({
      companyId: 'company-1',
      user: { id: 'user-1', email: 'max@example.com', user_metadata: {} },
      tourId: 't',
      machines: [],
      warehouseId: null,
      warehouseName: null,
    })
    expect(entry.metadata._user_display).toBe('max@example.com')
    expect(entry.metadata.machine_count).toBe(0)
    expect(entry.metadata.warehouse_id).toBeNull()
    expect(entry.metadata.warehouse_name).toBeNull()
  })

  it('handles a null user and missing company', () => {
    const entry = buildTourStartedEntry({
      companyId: undefined,
      user: null,
      tourId: 't',
      machines,
      warehouseId: 'wh-1',
      warehouseName: null,
    })
    expect(entry.company_id).toBeNull()
    expect(entry.user_id).toBeNull()
    expect(entry.metadata._user_email).toBeNull()
    expect(entry.metadata._user_display).toBeNull()
  })
})
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useRefillWizard.tourStarted.test.ts
```

Expected: FAIL — `buildTourStartedEntry` is not exported (`SyntaxError` / `undefined is not a function`).

- [ ] **Step 3: Implement the builder**

In `management-frontend/app/composables/useRefillWizard.ts`, directly **before** the line `export function useRefillWizard()` (the single unambiguous anchor), add:

```ts
// ── tour_started activity payload ──────────────────────────────────────────

export interface TourStartedEntryInput {
  companyId: string | null | undefined
  user: { id?: string; email?: string | null; user_metadata?: Record<string, unknown> } | null
  tourId: string
  machines: { id: string; name: string }[]
  warehouseId: string | null
  warehouseName: string | null
}

/**
 * Build the `activity_log` insert payload for a tour start (spec:
 * docs/superpowers/specs/2026-06-11-ios-dashboard-activity-feed-design.md §3.1).
 * Pure function — unit-tested in __tests__/useRefillWizard.tourStarted.test.ts.
 * The iOS app writes a field-compatible payload; keep the two in sync.
 */
export function buildTourStartedEntry(input: TourStartedEntryInput) {
  const meta = (input.user?.user_metadata ?? {}) as Record<string, unknown>
  const fullName = [meta.first_name, meta.last_name]
    .filter(Boolean).join(' ').trim()
  const userDisplay = fullName || input.user?.email || null
  return {
    company_id: input.companyId ?? null,
    user_id: input.user?.id ?? null,
    entity_type: 'stock',
    entity_id: input.tourId,
    action: 'tour_started',
    metadata: {
      tour_id: input.tourId,
      machine_count: input.machines.length,
      machine_ids: input.machines.map(m => m.id),
      machine_names: input.machines.map(m => m.name),
      warehouse_id: input.warehouseId,
      warehouse_name: input.warehouseName,
      _user_email: input.user?.email ?? null,
      _user_display: userDisplay,
    },
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd management-frontend && npx vitest run app/composables/__tests__/useRefillWizard.tourStarted.test.ts
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/composables/useRefillWizard.ts management-frontend/app/composables/__tests__/useRefillWizard.tourStarted.test.ts
git commit -m "feat(pwa): pure tour_started activity payload builder + tests" -- management-frontend/app/composables/useRefillWizard.ts management-frontend/app/composables/__tests__/useRefillWizard.tourStarted.test.ts
```

### Task 2: Wire `tour_started` into `startTour()` + tour_id in deduct metadata + history label

**Files:**
- Modify: `management-frontend/app/composables/useRefillWizard.ts` (inside `async function startTour()`, currently ~lines 543–612)
- Modify: `management-frontend/app/composables/useActivityLog.ts` (`actionLabel`, ~line 148)

- [ ] **Step 1: Add tour_id to the deduction metadata**

In `startTour()`, change the `p_metadata` line of the `deduct_warehouse_stock_fifo` call (~line 583):

```ts
            p_metadata: { _user_email: session?.user?.email ?? null, tour_id: tourId.value },
```

- [ ] **Step 2: Write the tour_started entry after deductions succeed**

In `startTour()`, directly **after** the line `machines.value = tourMachines` (~line 595) and before `currentMachineIndex.value = 0`, insert:

```ts
      // Tour-started activity entry (non-critical — failures only logged).
      // Written only after all deductions succeeded so an aborted tour start
      // never leaves an orphaned feed entry (spec §3.1).
      try {
        // Name lookup failure must not suppress the entry itself — a
        // name-less tour_started beats no entry.
        let warehouseName: string | null = null
        try {
          if (selectedWarehouseId.value) {
            const { data: wh } = await (supabase as any)
              .from('warehouses')
              .select('name')
              .eq('id', selectedWarehouseId.value)
              .maybeSingle()
            warehouseName = wh?.name ?? null
          }
        } catch { /* non-critical */ }
        await (supabase as any).from('activity_log').insert(
          buildTourStartedEntry({
            companyId: organization.value?.id,
            user: session?.user ?? null,
            tourId: tourId.value,
            machines: tourMachines.map(m => ({ id: m.id, name: m.name })),
            warehouseId: selectedWarehouseId.value,
            warehouseName,
          }),
        )
      } catch (logErr) {
        console.warn('[refillWizard] tour_started activity_log write failed:', logErr)
      }
```

Notes for the implementer:
- `organization` is already available in the composable (used by the existing `stock_refill_tour` insert at ~line 792).
- `session` is already in scope (fetched at the top of `startTour()`).
- `buildTourStartedEntry` is in the same file (Task 1) — no import needed.

- [ ] **Step 3: Add the history label**

In `useActivityLog.ts`, extend the `labels` map inside `actionLabel` (~line 149):

```ts
            sale_recorded: 'Sale recorded',
            credit_sent: 'Credit sent',
            stock_updated: 'Stock updated',
            stock_refill_all: 'All trays refilled',
            tour_started: 'Tour started',
```

- [ ] **Step 4: Run the full PWA test suite**

```bash
cd management-frontend && npx vitest run
```

Expected: all suites PASS (no regressions; the new block is fire-and-forget inside `startTour`, which has no existing unit test).

- [ ] **Step 5: Commit**

```bash
git add management-frontend/app/composables/useRefillWizard.ts management-frontend/app/composables/useActivityLog.ts
git commit -m "feat(pwa): write tour_started activity event + stamp tour_id into warehouse deductions" -- management-frontend/app/composables/useRefillWizard.ts management-frontend/app/composables/useActivityLog.ts
```

---

## Chunk 2: iOS — feed data layer

### Task 3: `ActivityFeed.swift` model + pure builders + pbxproj registration

**Files:**
- Create: `ios/VMflow/Models/ActivityFeed.swift`
- Modify: `ios/VMflow.xcodeproj/project.pbxproj` (4 insertions; precedent: `SuppressedSale.swift` at lines 72/161/230/708)

- [ ] **Step 1: Create `ios/VMflow/Models/ActivityFeed.swift`**

Complete file content:

```swift
import Foundation

// MARK: - Raw rows (PostgREST decoding)

/// Row from `activity_log` for the dashboard feed.
/// Only the columns/metadata keys the feed renders; metadata is decoded
/// tolerantly because old rows may carry fewer fields.
struct ActivityLogRow: Decodable, Equatable {
    let id: UUID
    let createdAt: Date
    let action: String
    let metadata: ActivityLogMetadata?

    enum CodingKeys: String, CodingKey {
        case id, action, metadata
        case createdAt = "created_at"
    }
}

struct ActivityLogMetadata: Decodable, Equatable {
    let tourId: String?
    let machineName: String?
    let traysRefilled: Int?
    let totalAdded: Int?
    let machineCount: Int?
    let machineNames: [String]?
    let warehouseName: String?
    let userDisplay: String?
    let products: [ActivityProductLine]?

    enum CodingKeys: String, CodingKey {
        case products
        case tourId = "tour_id"
        case machineName = "machine_name"
        case traysRefilled = "trays_refilled"
        case totalAdded = "total_added"
        case machineCount = "machine_count"
        case machineNames = "machine_names"
        case warehouseName = "warehouse_name"
        case userDisplay = "_user_display"
    }
}

struct ActivityProductLine: Decodable, Equatable {
    let productName: String?
    let quantity: Int?

    enum CodingKeys: String, CodingKey {
        case quantity
        case productName = "product_name"
    }
}

/// Row from `warehouse_transactions` (transaction_type = 'incoming') with
/// FK-joined product and warehouse names.
struct IntakeTransactionRow: Decodable, Equatable {
    let id: UUID
    let createdAt: Date
    let warehouseId: UUID?
    let userId: UUID?
    let quantityChange: Int
    let products: NameOnly?
    let warehouses: NameOnly?

    struct NameOnly: Decodable, Equatable { let name: String? }

    enum CodingKeys: String, CodingKey {
        case id, products, warehouses
        case createdAt = "created_at"
        case warehouseId = "warehouse_id"
        case userId = "user_id"
        case quantityChange = "quantity_change"
    }
}

// MARK: - Feed items

struct RefillActivity: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let machineName: String
    let traysRefilled: Int
    let totalAdded: Int
    let userDisplay: String?
    let tourId: String?
    let products: [(name: String, quantity: Int)]

    static func == (lhs: RefillActivity, rhs: RefillActivity) -> Bool {
        lhs.id == rhs.id && lhs.createdAt == rhs.createdAt
    }
}

struct TourActivity: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let userDisplay: String?
    let machineCount: Int
    let machineNames: [String]
    let warehouseName: String?
    let tourId: String?
}

/// One intake "session": consecutive incoming warehouse transactions by the
/// same user into the same warehouse with ≤15 min between bookings.
struct IntakeGroup: Identifiable, Equatable {
    /// Deterministic: id of the OLDEST transaction in the group — stable
    /// across reloads so row expansion state survives (spec §1).
    let id: UUID
    /// Newest transaction time in the group (used for sorting/day grouping).
    let date: Date
    let userId: UUID?
    var userDisplay: String?
    let warehouseName: String?
    let totalUnits: Int
    let products: [(name: String, quantity: Int)]

    var productCount: Int { products.count }

    static func == (lhs: IntakeGroup, rhs: IntakeGroup) -> Bool {
        lhs.id == rhs.id && lhs.date == rhs.date && lhs.userDisplay == rhs.userDisplay
    }
}

/// One entry in the dashboard "Recent Activity" timeline.
enum ActivityFeedItem: Identifiable, Equatable {
    case sale(SaleWithMachine)
    case machineRefilled(RefillActivity)
    case tourStarted(TourActivity)
    case stockIntake(IntakeGroup)

    var id: String {
        switch self {
        case .sale(let s): return "sale-\(s.id.uuidString)"
        case .machineRefilled(let r): return "refill-\(r.id.uuidString)"
        case .tourStarted(let t): return "tour-\(t.id.uuidString)"
        case .stockIntake(let g): return "intake-\(g.id.uuidString)"
        }
    }

    var date: Date {
        switch self {
        case .sale(let s): return s.sale.createdAt
        case .machineRefilled(let r): return r.createdAt
        case .tourStarted(let t): return t.createdAt
        case .stockIntake(let g): return g.date
        }
    }
}

// MARK: - Pure builders (no I/O — kept testable)

enum ActivityFeedBuilder {

    /// Max gap between two bookings that still counts as one intake session.
    static let intakeSessionGap: TimeInterval = 15 * 60

    /// Group incoming warehouse transactions into intake sessions.
    /// `rows` may arrive in any order; they are sorted ascending internally.
    /// A new group starts when the user or warehouse changes, or the gap to
    /// the previous transaction exceeds `intakeSessionGap`.
    static func groupIntakes(_ rows: [IntakeTransactionRow]) -> [IntakeGroup] {
        let sorted = rows.sorted { $0.createdAt < $1.createdAt }
        var groups: [IntakeGroup] = []
        var current: [IntakeTransactionRow] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            // Aggregate quantities per product name, preserving first-seen order.
            var order: [String] = []
            var qty: [String: Int] = [:]
            for row in current {
                let name = row.products?.name ?? "—"
                if qty[name] == nil { order.append(name) }
                qty[name, default: 0] += row.quantityChange
            }
            groups.append(IntakeGroup(
                id: first.id,
                date: last.createdAt,
                userId: first.userId,
                userDisplay: nil,
                warehouseName: first.warehouses?.name,
                totalUnits: current.reduce(0) { $0 + $1.quantityChange },
                products: order.map { (name: $0, quantity: qty[$0] ?? 0) }
            ))
            current = []
        }

        for row in sorted {
            if let prev = current.last {
                let sameSession = prev.userId == row.userId
                    && prev.warehouseId == row.warehouseId
                    && row.createdAt.timeIntervalSince(prev.createdAt) <= intakeSessionGap
                if !sameSession { flush() }
            }
            current.append(row)
        }
        flush()
        return groups
    }

    /// Map activity_log rows to feed items. Unknown actions are skipped.
    static func makeActivityItems(_ rows: [ActivityLogRow]) -> [ActivityFeedItem] {
        rows.compactMap { row in
            switch row.action {
            case "stock_refill_tour":
                return .machineRefilled(RefillActivity(
                    id: row.id,
                    createdAt: row.createdAt,
                    machineName: row.metadata?.machineName ?? "—",
                    traysRefilled: row.metadata?.traysRefilled ?? 0,
                    totalAdded: row.metadata?.totalAdded ?? 0,
                    userDisplay: row.metadata?.userDisplay,
                    tourId: row.metadata?.tourId,
                    products: (row.metadata?.products ?? []).compactMap { line in
                        guard let name = line.productName else { return nil }
                        return (name: name, quantity: line.quantity ?? 0)
                    }
                ))
            case "tour_started":
                let names = row.metadata?.machineNames ?? []
                return .tourStarted(TourActivity(
                    id: row.id,
                    createdAt: row.createdAt,
                    userDisplay: row.metadata?.userDisplay,
                    machineCount: row.metadata?.machineCount ?? names.count,
                    machineNames: names,
                    warehouseName: row.metadata?.warehouseName,
                    tourId: row.metadata?.tourId
                ))
            default:
                return nil
            }
        }
    }

    /// Merge all sources into one timeline, newest first.
    static func mergeFeed(
        sales: [SaleWithMachine],
        activityRows: [ActivityLogRow],
        intakeGroups: [IntakeGroup]
    ) -> [ActivityFeedItem] {
        var items: [ActivityFeedItem] = sales.map { .sale($0) }
        items.append(contentsOf: makeActivityItems(activityRows))
        items.append(contentsOf: intakeGroups.map { .stockIntake($0) })
        return items.sorted { $0.date > $1.date }
    }
}
```

- [ ] **Step 2: Register the file in `project.pbxproj`**

The project does NOT use file-system-synchronized groups — new files need 4 entries. First verify the synthetic UUIDs are unused:

```bash
grep -c "FE02AA03BB04CC05DD06EE07\|FE12AA13BB14CC15DD16EE17" ios/VMflow.xcodeproj/project.pbxproj
```

Expected: `0`. Then make 4 edits, each anchored on the existing `SuppressedSale.swift` entries (search for them; the line numbers ~72/~161/~230/~708 may have drifted):

1. In the `PBXBuildFile` section, directly after the `SuppressedSale.swift in Sources` line:
```
		FE02AA03BB04CC05DD06EE07 /* ActivityFeed.swift in Sources */ = {isa = PBXBuildFile; fileRef = FE12AA13BB14CC15DD16EE17 /* ActivityFeed.swift */; };
```
2. In the `PBXFileReference` section, directly after the `SuppressedSale.swift` file reference:
```
		FE12AA13BB14CC15DD16EE17 /* ActivityFeed.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ActivityFeed.swift; sourceTree = "<group>"; };
```
3. In the Models group's `children` list (the block listing `Sale.swift`, `SuppressedSale.swift`, `Tray.swift`, …), after the `SuppressedSale.swift` child line:
```
				FE12AA13BB14CC15DD16EE17 /* ActivityFeed.swift */,
```
4. In the `PBXSourcesBuildPhase` `files` list, after the `SuppressedSale.swift in Sources` line:
```
				FE02AA03BB04CC05DD06EE07 /* ActivityFeed.swift in Sources */,
```
**Careful:** this must be the build-file UUID from edit 1 (FE02…07), not the file-reference UUID (FE12…17).

- [ ] **Step 3: Build**

```bash
xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet build
```

Expected: `BUILD SUCCEEDED` (warnings ok). If "ActivityFeed.swift not found" → re-check edit 2/3 paths; if "undefined symbol" → edit 4 missing.

- [ ] **Step 4: Commit**

```bash
git add ios/VMflow/Models/ActivityFeed.swift ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): activity feed models + pure intake-grouping/merge builders" -- ios/VMflow/Models/ActivityFeed.swift ios/VMflow.xcodeproj/project.pbxproj
```

### Task 4: RealtimeService — `activityVersion`

**Files:**
- Modify: `ios/VMflow/Services/RealtimeService.swift`

- [ ] **Step 1: Add the version counter, stream, and consumer**

Five edits following the existing pattern exactly (don't skip the last one — a comment touch-up):

After `@Published var warehouseVersion: Int = 0` (line 16):
```swift
    @Published var activityVersion: Int = 0
```

After the `warehouseStream` declaration (line 47) — MUST stay before `ch.subscribe()` (see the comment block at lines 31–42):
```swift
        let activityStream = ch.postgresChange(InsertAction.self, schema: "public", table: "activity_log")
```

In the `listenTask` block, extend the parallel consumption (lines 57–62):
```swift
            async let a: () = consumeActivity(activityStream)
            _ = await (s, t, m, e, w, a)
```
(replace the existing `_ = await (s, t, m, e, w)` line)

After `consumeWarehouse` (line 106-111), add:
```swift
    private func consumeActivity(_ stream: AsyncStream<InsertAction>) async {
        for await _ in stream {
            activityVersion += 1
            print("[Realtime] New activity_log entry detected")
        }
    }
```

And fifth, update the now-stale comment inside `listenTask` (line ~51): `// The join payload now includes all five postgres_changes filters` → `all six postgres_changes filters`.

- [ ] **Step 2: Build**

```bash
xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/Services/RealtimeService.swift
git commit -m "feat(ios): realtime activity_log inserts bump activityVersion" -- ios/VMflow/Services/RealtimeService.swift
```

### Task 5: DashboardViewModel + DashboardView — merged feed with infinite scroll

These two files change together (the ViewModel's published property types change, so the view must adapt in the same compile unit).

**Files:**
- Modify: `ios/VMflow/ViewModels/DashboardViewModel.swift`
- Modify: `ios/VMflow/Views/Dashboard/DashboardView.swift`

- [ ] **Step 1: ViewModel — replace the recent-sales state with feed state**

In `DashboardViewModel.swift` replace (lines 29–41):

```swift
    @Published var recentSales: [SaleWithMachine] = []

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

with:

```swift
    /// Merged dashboard timeline: sales + refills + tour starts + intake sessions.
    @Published var recentActivity: [ActivityFeedItem] = []

    /// Number of days back from start_of_today the activity window covers.
    /// 0 = today only; 6 = last 7 days; 13 = last 14 days; 7N−1 after N expansions.
    @Published var activityDaysBack: Int = 0

    /// Becomes false when widening the window brings no additional source rows
    /// (history exhausted). Resets to true when a reload brings in more rows
    /// (e.g. realtime delivery into the current window).
    @Published var hasMoreActivity: Bool = true

    /// True while an infinite-scroll fetch is in flight — drives the sentinel spinner.
    @Published var isLoadingMoreActivity: Bool = false

    /// Raw source-row count (sales + activity rows + intake transactions) of the
    /// last load. Exhaustion compares RAW rows, not merged items — new transactions
    /// merging into an existing boundary IntakeGroup would otherwise leave the
    /// merged count unchanged and falsely signal "exhausted" (spec §2). Published
    /// (read-only) because the infinite-scroll sentinel keys its `.task(id:)` on it
    /// to re-arm after every completed load.
    @Published private(set) var rawSourceRowCount = 0

    /// user_id → display name cache for intake attribution (users table lookups).
    private var userNameCache: [UUID: String] = [:]
```

- [ ] **Step 2: ViewModel — rename the orchestration call**

In `loadDashboard()` (line 74), change `async let recentTask: () = loadRecentSales()` to:

```swift
            async let recentTask: () = loadRecentActivity()
```

- [ ] **Step 3: ViewModel — replace `loadRecentSales()` with the three-source load**

Replace the entire `// MARK: - Recent Sales` section (the `loadRecentSales()` function, lines 259–338) with:

```swift
    // MARK: - Recent Activity (sales + refills + tour starts + intakes)

    private func loadRecentActivity() async throws {
        // Window start: start_of_today − activityDaysBack days.
        // daysBack=0 → start_of_today (only today's events since midnight, NOT last 24h).
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let windowStart = calendar.date(byAdding: .day, value: -activityDaysBack, to: startOfToday)!

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let windowStartString = formatter.string(from: windowStart)

        // All three sources fail-or-succeed together (spec §2: no sales-only degrade).
        async let salesTask = fetchRecentSaleItems(windowStartString: windowStartString)
        async let activityTask = fetchActivityRows(windowStartString: windowStartString)
        async let intakeTask = fetchIntakeRows(windowStartString: windowStartString)
        let (sales, rawSalesCount) = try await salesTask
        let activityRows = try await activityTask
        let intakeRows = try await intakeTask

        var groups = ActivityFeedBuilder.groupIntakes(intakeRows)
        let names = await resolveUserNames(for: groups.compactMap { $0.userId })
        for i in groups.indices {
            if let uid = groups[i].userId { groups[i].userDisplay = names[uid] }
        }

        let rawBefore = rawSourceRowCount
        rawSourceRowCount = rawSalesCount + activityRows.count + intakeRows.count
        recentActivity = ActivityFeedBuilder.mergeFeed(
            sales: sales, activityRows: activityRows, intakeGroups: groups
        )

        // Recovery: if a reload brought in more raw rows than before (e.g. realtime
        // delivery into the current window), un-exhaust the infinite scroll.
        if rawSourceRowCount > rawBefore {
            hasMoreActivity = true
        }
    }

    /// Existing recent-sales pipeline, unchanged: sales + machine names + product
    /// fallback via trays. Returns the display items plus the raw row count.
    private func fetchRecentSaleItems(windowStartString: String) async throws -> ([SaleWithMachine], Int) {
        // Fetch sales with snapshotted product via FK join.
        let sales: [Sale] = try await client
            .from("sales")
            .select("id, created_at, item_price, item_number, machine_id, embedded_id, channel, product_id, products(name, image_path)")
            .gte("created_at", value: windowStartString)
            .order("created_at", ascending: false)
            .execute()
            .value

        // Fetch machine names for these sales
        let machineIds = Set(sales.compactMap { $0.machineId })
        var machineNames: [UUID: String] = [:]

        if !machineIds.isEmpty {
            let machines: [VendingMachine] = try await client
                .from("vendingMachine")
                .select("id, name, location_lat, location_lon, embedded, country_code")
                .in("id", values: machineIds.map { $0.uuidString })
                .execute()
                .value

            for m in machines {
                machineNames[m.id] = m.displayName
            }
        }

        // Fallback: fetch tray→product lookup only for old sales without product_id
        let salesWithoutProduct = sales.filter { $0.productId == nil && $0.machineId != nil }
        var trayProductLookup: [String: (name: String?, imagePath: String?)] = [:]

        if !salesWithoutProduct.isEmpty {
            let fallbackMachineIds = Set(salesWithoutProduct.compactMap { $0.machineId })
            let trays: [Tray] = try await client
                .from("machine_trays")
                .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued, sellprice)")
                .in("machine_id", values: fallbackMachineIds.map { $0.uuidString })
                .execute()
                .value

            for tray in trays {
                let key = "\(tray.machineId)_\(tray.itemNumber)"
                trayProductLookup[key] = (name: tray.products?.name, imagePath: tray.products?.imagePath)
            }
        }

        let items = sales.map { sale in
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
        return (items, sales.count)
    }

    /// Refill + tour-start rows. RLS scopes to the user's company.
    private func fetchActivityRows(windowStartString: String) async throws -> [ActivityLogRow] {
        try await client
            .from("activity_log")
            .select("id, created_at, action, metadata")
            .in("action", values: ["stock_refill_tour", "tour_started"])
            .gte("created_at", value: windowStartString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// Incoming warehouse transactions with product/warehouse names joined.
    /// Both type strings are read: the PWA books intakes as 'incoming', the
    /// iOS app as 'intake' (pre-existing cross-client divergence).
    private func fetchIntakeRows(windowStartString: String) async throws -> [IntakeTransactionRow] {
        try await client
            .from("warehouse_transactions")
            .select("id, created_at, warehouse_id, user_id, quantity_change, products(name), warehouses(name)")
            .in("transaction_type", values: ["incoming", "intake"])
            .gte("created_at", value: windowStartString)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    /// Resolve display names for intake attribution. The users-table FK points
    /// to auth.users, so PostgREST can't embed it — same lookup pattern as
    /// ProductDetailSheet. Failures degrade to no name (non-critical).
    private func resolveUserNames(for ids: [UUID]) async -> [UUID: String] {
        struct UserRow: Decodable {
            let id: UUID
            let firstName: String?
            let lastName: String?
            let email: String?
            enum CodingKeys: String, CodingKey {
                case id, email
                case firstName = "first_name"
                case lastName = "last_name"
            }
        }

        let missing = Array(Set(ids.filter { userNameCache[$0] == nil }))
        if !missing.isEmpty {
            let rows: [UserRow] = (try? await client
                .from("users")
                .select("id, first_name, last_name, email")
                .in("id", values: missing.map { $0.uuidString })
                .execute()
                .value) ?? []
            for u in rows {
                let full = [u.firstName, u.lastName].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: " ")
                userNameCache[u.id] = full.isEmpty ? (u.email ?? String(u.id.uuidString.prefix(8))) : full
            }
        }

        var out: [UUID: String] = [:]
        for id in ids { out[id] = userNameCache[id] }
        return out
    }
```

- [ ] **Step 4: ViewModel — replace `loadMoreRecentSales()`**

Replace the `// MARK: - Load More` section (lines 340–370 — careful: line 371 is the **class's** closing brace and must stay) with:

```swift
    // MARK: - Load More (infinite scroll)

    /// Expand the activity window: today (1 day) → 7 days → 14 days → 21 days → …
    /// Triggered by the feed's bottom sentinel. Each call adds 7 more days;
    /// the first jumps from 1 to 7 (i.e. +6 days).
    func loadMoreRecentActivity() async {
        guard !isLoadingMoreActivity, !isLoading, hasMoreActivity else { return }

        let previousDaysBack = activityDaysBack
        let nextDaysBack = previousDaysBack == 0 ? 6 : previousDaysBack + 7

        isLoadingMoreActivity = true
        defer { isLoadingMoreActivity = false }

        let rawBefore = rawSourceRowCount
        activityDaysBack = nextDaysBack

        do {
            try await loadRecentActivity()
            // Same raw row count in a wider window → history exhausted.
            if rawSourceRowCount == rawBefore {
                hasMoreActivity = false
            }
        } catch is CancellationError {
            // Cancelled (sentinel unmounted by a concurrent dashboard reload, or
            // scrolled far away). Do NOT revert the window: a concurrent
            // loadDashboard already read the widened value — reverting would make
            // the sentinel re-fetch the same window and falsely flag "exhausted".
            // A scroll-away cancel merely skips one 7-day step on the next fire.
        } catch {
            // URLSession can surface cancellation as URLError(.cancelled), which
            // lands here instead of the CancellationError case — same no-revert
            // treatment.
            if Task.isCancelled { return }
            // Real server/network error: revert window so the sentinel retries.
            activityDaysBack = previousDaysBack
            self.error = error.localizedDescription
        }
    }
```

Known accepted limitation: after a real network error the sentinel doesn't auto-retry until it re-mounts (scroll away/back, pull-to-refresh, or a realtime reload) — in the spirit of the old button, which also required a manual tap to retry.

- [ ] **Step 5: ViewModel — fix the loading overlay guard in the View + models doc comment**

(Noted here because it compiles against the ViewModel.) In `DashboardView.swift` line 80, `viewModel.dailySales.isEmpty` stays as-is — no change needed. (The overlay never referenced `recentSales`.)

Also update the doc comment on `IntakeTransactionRow` in `ios/VMflow/Models/ActivityFeed.swift` (~line 53) from `/// Row from `warehouse_transactions` (transaction_type = 'incoming') with` to `/// Row from `warehouse_transactions` (transaction_type 'incoming'/'intake') with` — the feed reads both type strings (PWA writes 'incoming', iOS writes 'intake').

- [ ] **Step 6: View — realtime trigger + section replacement**

In `DashboardView.swift`:

(a) Extend `realtimeVersion` (lines 28–30):
```swift
    private var realtimeVersion: Int {
        realtime.salesVersion + realtime.machinesVersion + realtime.embeddedVersion + realtime.activityVersion
    }
```

(b) Add the expansion state next to the other `@State` vars (~line 19):
```swift
    /// Feed rows (refill/tour/intake) whose detail list is expanded.
    @State private var expandedActivityIds: Set<String> = []
```

(c) In the body, rename the section call `recentSalesSection` → `recentActivitySection` (line 47, comment line 46: `// Recent Activity`).

(d) Replace the whole `// MARK: - Recent Sales` block — `recentSalesSection` (lines 520–564) AND `loadMoreButton` (lines 566–597) — with:

```swift
    // MARK: - Recent Activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity")
                .font(.headline)

            // Terminal empty state ONLY when history is exhausted — an empty
            // window with hasMoreActivity still true must render the sentinel
            // below, otherwise older history would be permanently unreachable
            // (the old "Load more" button rendered even when today was empty).
            if viewModel.recentActivity.isEmpty && !viewModel.isLoading && !viewModel.hasMoreActivity {
                Text("No recent activity")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                let grouped = groupFeedItemsByDay(viewModel.recentActivity)
                // LazyVStack: only the rows visible in the ScrollView's viewport are
                // instantiated. Without it, large windows (e.g. 21+ days) render
                // hundreds of rows eagerly, each spawning an AsyncImage
                // HTTP request — iOS kills the app under memory pressure.
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(grouped, id: \.date) { group in
                        DaySectionHeader(
                            label: dayLabel(for: group.date),
                            count: group.items.count,
                            unit: String(localized: "entries")
                        )
                        ForEach(group.items) { item in
                            feedRow(for: item)
                        }
                    }

                    // Infinite-scroll sentinel: when it becomes visible the next
                    // window loads. Hidden during full dashboard loads so the
                    // initial load and a window expansion never run concurrently
                    // (loadDashboard doesn't set isLoadingMoreActivity, so the
                    // loadMore guard alone wouldn't cover that race) — and each
                    // completed dashboard load re-inserts the sentinel, whose
                    // fresh .task fires on appearance (auto-fill on short feeds).
                    // Keyed on the RAW row count so a completed expansion re-arms
                    // it while it is still on screen, even if all new rows merged
                    // into an existing boundary intake group.
                    if viewModel.hasMoreActivity && !viewModel.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .task(id: viewModel.rawSourceRowCount) {
                            await viewModel.loadMoreRecentActivity()
                        }
                    }
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }

    @ViewBuilder
    private func feedRow(for item: ActivityFeedItem) -> some View {
        switch item {
        case .sale(let saleItem):
            RecentSaleRow(item: saleItem) {
                guard let pid = saleItem.sale.productId else { return }
                selectedProduct = ProductSelection(
                    id: pid,
                    name: saleItem.productName ?? "Item #\(saleItem.sale.itemNumber ?? 0)",
                    imagePath: saleItem.productImagePath,
                    sellprice: saleItem.sale.itemPrice
                )
            }

        case .machineRefilled(let refill):
            ActivityEventRow(
                icon: "shippingbox.fill",
                tint: .green,
                title: refill.machineName,
                subtitle: refillSubtitle(refill),
                date: refill.createdAt,
                detailLines: refill.products.map { "\($0.quantity)× \($0.name)" },
                isExpanded: expandedActivityIds.contains(item.id),
                onToggle: { toggleExpanded(item.id) }
            )

        case .tourStarted(let tour):
            ActivityEventRow(
                icon: "figure.walk",
                tint: .indigo,
                title: String(localized: "Tour started"),
                subtitle: tourSubtitle(tour),
                date: tour.createdAt,
                detailLines: tour.machineNames,
                isExpanded: expandedActivityIds.contains(item.id),
                onToggle: { toggleExpanded(item.id) }
            )

        case .stockIntake(let intake):
            ActivityEventRow(
                icon: "tray.and.arrow.down.fill",
                tint: .orange,
                title: String(localized: "Stock intake"),
                subtitle: intakeSubtitle(intake),
                date: intake.date,
                detailLines: intake.products.map { "\($0.quantity)× \($0.name)" },
                isExpanded: expandedActivityIds.contains(item.id),
                onToggle: { toggleExpanded(item.id) }
            )
        }
    }

    private func toggleExpanded(_ id: String) {
        if expandedActivityIds.contains(id) {
            expandedActivityIds.remove(id)
        } else {
            expandedActivityIds.insert(id)
        }
    }

    private func refillSubtitle(_ refill: RefillActivity) -> String {
        var parts: [String] = []
        if let user = refill.userDisplay {
            parts.append(String(localized: "Filled by \(user)"))
        }
        parts.append(String(localized: "\(refill.totalAdded) items"))
        return parts.joined(separator: " · ")
    }

    private func tourSubtitle(_ tour: TourActivity) -> String {
        var parts: [String] = []
        if let user = tour.userDisplay { parts.append(user) }
        parts.append(String(localized: "\(tour.machineCount) machines"))
        if let wh = tour.warehouseName { parts.append(wh) }
        return parts.joined(separator: " · ")
    }

    private func intakeSubtitle(_ intake: IntakeGroup) -> String {
        var parts: [String] = []
        if let user = intake.userDisplay { parts.append(user) }
        parts.append(String(localized: "\(intake.productCount) products"))
        if let wh = intake.warehouseName { parts.append(wh) }
        return parts.joined(separator: " · ")
    }
```

(e) Replace the day-grouping helpers (`DashboardDayGroup` struct + `groupDashboardSalesByDay`, lines 664–677) with a feed-item version (keep `dayLabel(for:)` unchanged):

```swift
    private struct FeedDayGroup {
        let date: Date
        let items: [ActivityFeedItem]
    }

    private func groupFeedItemsByDay(_ items: [ActivityFeedItem]) -> [FeedDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { item in
            calendar.startOfDay(for: item.date)
        }
        return grouped.keys.sorted(by: >).map { date in
            FeedDayGroup(date: date, items: grouped[date]!.sorted { $0.date > $1.date })
        }
    }
```

(f) At the end of the file (after `RecentSaleRow`, before the `timeAgo` helper), add the shared event-row view:

```swift
// MARK: - Activity Event Row

/// Non-sale feed row: tinted icon circle, title, subtitle, time — visually in
/// rhythm with RecentSaleRow. Tapping toggles an inline detail list (products
/// or machine names); rows without details don't react.
struct ActivityEventRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let date: Date
    let detailLines: [String]
    let isExpanded: Bool
    var onToggle: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.subheadline)
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatTime(date))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !detailLines.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
            }

            if isExpanded && !detailLines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(detailLines, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 48)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !detailLines.isEmpty else { return }
            withAnimation(.snappy(duration: 0.2)) { onToggle() }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
```

(g) Update the two stale doc comments: `DashboardViewModel.swift` line 4 (`/// Drives the Dashboard view with KPIs, 30-day chart data, and recent sales.` → `…and the recent-activity feed.`) and `DashboardView.swift` line 4 (`/// Main dashboard with KPIs, 30-day chart, recent sales, and quick actions.` → `…30-day chart, recent activity, and quick actions.`).

- [ ] **Step 7: Build**

```bash
xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet build
```

Expected: `BUILD SUCCEEDED`. Typical failures: leftover references to `recentSales` / `hasMoreSales` / `loadMoreRecentSales` / `recentSalesDaysBack` (grep the two files for them; there must be none).

```bash
grep -n "recentSales\|hasMoreSales\|isLoadingMoreSales\|loadMoreRecentSales" ios/VMflow/ViewModels/DashboardViewModel.swift ios/VMflow/Views/Dashboard/DashboardView.swift
```

Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add ios/VMflow/ViewModels/DashboardViewModel.swift ios/VMflow/Views/Dashboard/DashboardView.swift
git commit -m "feat(ios): dashboard recent-activity feed (sales+refills+intakes+tours) with infinite scroll" -- ios/VMflow/ViewModels/DashboardViewModel.swift ios/VMflow/Views/Dashboard/DashboardView.swift
```

---

## Chunk 3: iOS writers + i18n + verification

### Task 6: RefillWizardViewModel — `tour_started` write + tour_id in deduct metadata

**Files:**
- Modify: `ios/VMflow/ViewModels/RefillWizardViewModel.swift`

- [ ] **Step 1: Generalize `writeActivityLog` for tour-level events**

The function at line 1962 currently requires a machine. Change its signature and the two machine-dependent metadata fields:

```swift
    private func writeActivityLog(machineId: UUID?, machineName: String?, action: String, extraMetadata: [String: AnyJSON]) async {
```

Inside, replace the `metadata` dictionary construction INCLUDING the existing `if let warehouseId` block (lines ~1982–1991 — the snippet below already contains that block; replacing only the dict literal would leave it duplicated):

```swift
            var metadata: [String: AnyJSON] = [
                "tour_id": .string(tourId),
                "_user_email": user.email.map { .string($0) } ?? .null,
                "_user_display": userDisplay.map { .string($0) } ?? .null,
            ]
            if let machineId { metadata["machine_id"] = .string(machineId.uuidString) }
            if let machineName { metadata["machine_name"] = .string(machineName) }
            if let warehouseId = selectedWarehouseId {
                metadata["warehouse_id"] = .string(warehouseId.uuidString)
            }
```

And in the `.insert([...])` payload, replace the `entity_id` line:

```swift
                    "entity_id": AnyJSON.string(machineId?.uuidString ?? tourId),
```

The two existing call sites (`recordRefillSuccess` line 1903, `skipMachine` line 1939) pass non-optional values and compile unchanged.

- [ ] **Step 2: Write `tour_started` in `startTour()`**

In `startTour()` (line 1610), after the warehouse-deduction block (lines 1672–1675) and **before** `currentMachineIndex = 0` (line 1677), insert:

```swift
        // Tour-started feed event — written after the warehouse deductions so an
        // aborted start never leaves an orphaned feed entry (spec §3.1). On iOS
        // deduction failures don't block the tour, so this runs on every start.
        // Field-compatible with the PWA's buildTourStartedEntry payload.
        let tourMachines = packedMachines
        var tourMeta: [String: AnyJSON] = [
            "machine_count": .integer(tourMachines.count),
            "machine_ids": .array(tourMachines.map { .string($0.id.uuidString) }),
            "machine_names": .array(tourMachines.map { .string($0.machine.displayName) }),
        ]
        if let warehouseName = warehouses.first(where: { $0.id == selectedWarehouseId })?.name {
            tourMeta["warehouse_name"] = .string(warehouseName)
        }
        await writeActivityLog(machineId: nil, machineName: nil, action: "tour_started", extraMetadata: tourMeta)
```

Note: the resume path (`resumeTour()`, restoring `tourId = state.tourId` at line 361) never calls `startTour()`, so the event is written exactly once per tour.

- [ ] **Step 3: Stamp tour_id into the deduction metadata**

In `deductWarehouseStock` (declared at 1684), change the `p_metadata` line (1724) to:

```swift
                        "p_metadata": AnyJSON.object([
                            "_user_email": userEmail.map { AnyJSON.string($0) } ?? AnyJSON.null,
                            "tour_id": AnyJSON.string(tourId)
                        ])
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add ios/VMflow/ViewModels/RefillWizardViewModel.swift
git commit -m "feat(ios): write tour_started activity event + stamp tour_id into warehouse deductions" -- ios/VMflow/ViewModels/RefillWizardViewModel.swift
```

### Task 7: Localizable.xcstrings — German translations

**Files:**
- Modify: `ios/VMflow/Resources/Localizable.xcstrings` (ADDITIVE ONLY — the file has uncommitted changes from other work)

- [ ] **Step 1: Add the new keys**

The file is a JSON string catalog (`"version" : "1.1"`, source language `en`, keys sorted alphabetically). First `Read` the file around an alphabetically adjacent existing key to copy the exact indentation style, then insert each new entry at its alphabetically correct position inside the `"strings"` object. Entry template (match the file's exact spacing — it uses ` : ` separators):

```json
    "Recent Activity" : {
      "localizations" : {
        "de" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Letzte Aktivität"
          }
        }
      }
    },
```

Keys to ADD — 9 new entries (en key → de value):

| Key | German |
|-----|--------|
| `Recent Activity` | `Letzte Aktivität` |
| `No recent activity` | `Keine Aktivität` |
| `Tour started` | `Tour gestartet` |
| `Stock intake` | `Ware eingebucht` |
| `entries` | `Einträge` |
| `Filled by %@` | `Gefüllt von %@` |
| `%lld items` | `%lld Artikel` |
| `%lld machines` | `%lld Automaten` |
| `Retry` | `Erneut versuchen` |

(`Retry` came in with the post-review fix 2746c5a: the sentinel renders a manual Retry row after a real load-more failure.)

**Do NOT add `%lld products`** — it already exists in the catalog (with the correct de value `%lld Produkte`); adding it again would create a duplicate JSON key that `json.load` silently swallows. Verify it instead (the Step 2 script covers it).

(`String(localized: "Filled by \(user)")` extracts as key `Filled by %@`; `String(localized: "\(n) items")` as `%lld items` — Int interpolations map to `%lld`. Note: spec §7 illustrates a combined key `Filled by %@ · %lld items`; the implementation deliberately splits it so a missing user name degrades gracefully — intended deviation.)

- [ ] **Step 2: Validate JSON + build**

```bash
python3 -c "import json; d=json.load(open('ios/VMflow/Resources/Localizable.xcstrings')); print('keys:', len(d['strings'])); [print('OK', k) for k in ['Recent Activity','No recent activity','Tour started','Stock intake','entries','Filled by %@','%lld items','%lld machines','%lld products','Retry'] if k in d['strings']]"
xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet build
```

Expected: 10 × `OK …`, then `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add ios/VMflow/Resources/Localizable.xcstrings
git commit -m "feat(ios): German strings for dashboard activity feed" -- ios/VMflow/Resources/Localizable.xcstrings
```

Note: this stages the file's pre-existing uncommitted hunks too if they overlap; check `git diff --cached -- ios/VMflow/Resources/Localizable.xcstrings` first — if unrelated changes from another session are present, commit anyway is acceptable ONLY if they are translation entries; otherwise use `git add -p` to stage only the new keys.

### Task 8: Final verification

- [ ] **Step 1: Full builds + tests**

```bash
xcodebuild -project ios/VMflow.xcodeproj -scheme VMflow -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet build
cd management-frontend && npx vitest run
```

Expected: `BUILD SUCCEEDED`, all Vitest suites PASS.

- [ ] **Step 2: Manual verification checklist (report to user — requires simulator/device with live backend)**

1. Dashboard shows "Letzte Aktivität" with historic refill entries (green, machine name) and intake entries (orange, grouped) interleaved with sales — without any new tour having been started (retroactive data).
2. Tapping a refill/intake/tour row expands its product/machine list; sale rows still open the product sheet.
3. Scrolling to the bottom auto-loads older windows (spinner appears, "Load more" button is gone); when history is exhausted the spinner disappears. An empty "today" auto-loads older days without any interaction.
4. Start a refill tour (PWA or iOS) → a "Tour gestartet" entry appears live (realtime) with user + machine count; `warehouse_transactions.metadata` of the deductions carries the `tour_id`.
5. Book a NEW stock intake → it does NOT appear live (no realtime on `warehouse_transactions`) but appears after pull-to-refresh, grouped with intakes of the same session.
6. Language: device in German shows „Letzte Aktivität"/„Tour gestartet"/„Ware eingebucht"; English shows the English strings.

- [ ] **Step 3: Report completion**

Summarize what was built, list the commits, and surface the manual checklist results (or which items remain for the user to verify on-device).

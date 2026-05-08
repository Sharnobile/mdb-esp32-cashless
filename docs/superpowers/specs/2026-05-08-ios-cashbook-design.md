# iOS Cash Book (Mid-Scope)

**Date:** 2026-05-08
**Status:** Draft

## Problem

The Kassenbuch web feature works well on the web but has no iOS counterpart. After a refill tour the operator returns to a parked van and ideally counts the collected cash on the spot — that is precisely the moment the iOS app is in hand. Today they have to switch to a laptop or web browser to record the entry, which is friction at exactly the wrong time. The dashboard also has no surface for the cash situation, so the operator can't tell at a glance how much money is sitting in the box or how long it has been since the last bank deposit.

We want a focused iOS implementation that covers the two daily actions (collect from machine; deposit to bank), surfaces current state on the dashboard, and lights up automatically at the natural workflow boundary — the end of a refill tour.

## Goals

- **Mid-scope feature parity**: the two cash-flow actions (`Geld aus Automat entnehmen`, `Geld auf Bank einzahlen`) plus the read-only overview (current balance, in-machines, last bank deposit, entries history). Configuration and admin actions stay web-only.
- **Refill-tour integration**: when a tour ends and exactly one Barkasse with non-zero cash sales matches the visited machines, an `WithdrawalSheet` opens automatically over the Tour-Complete summary. The amount field is pre-focused; description is pre-filled with `"Geldentnahme aus Automat (nach Tour)"`.
- **Dashboard tile**: a Mini-Flow card showing all three station values (`In Automaten` / `In der Kasse` / `Letzte Bankeinzahlung`) plus a chevron that pushes onto the full Cash Book screen.
- **Sidebar entry**: `cashBook` becomes the 9th `SidebarItem`, between `inbox` and `products`. iPhone surfaces it via the "More" tab, iPad/macOS via the persistent sidebar.
- **No DB or backend changes** — the iOS layer reads/writes the same tables and RPCs the web already uses.
- **Multi-Barkasse handling** — if a tour spans Barkassen of multiple cash books with cash sales, no auto-sheet pops; instead the Tour-Complete summary gains an inline block listing each Barkasse with its expected cash and a per-Barkasse `[→]` button.

## Non-Goals

- No correction, reversal, or settings sheets in iOS.
- No machine-assignment UI in iOS — this is a one-time setup the operator does in web.
- No create-Barkasse or delete-Barkasse flows in iOS.
- No PDF export — the GoBD-compliant PDF stays web-only (jsPDF has no first-class iOS equivalent and the export is rare).
- No client-side hash-chain verification — the web is the source of truth for that.
- No background sync / push notifications when someone else books an entry. iOS reflects state on cold launch and pull-to-refresh.
- No offline mode — the operator is expected to be online when collecting cash.
- No real-time updates via Supabase realtime channels.
- No iPad-specific layouts beyond what comes free from existing `AdaptiveRootView`.

## User Flows

### A. Standard cold open

1. User opens the iOS app, lands on Dashboard.
2. New `CashBookCard` shows three values for the last-used Barkasse.
3. Tap → push `CashBookView` onto the dashboard nav stack.

### B. After a refill tour (single Barkasse)

1. User completes refill tour → `RefillSummaryView` displays.
2. After the existing animations settle (Done button finishes fading in at ~1.7 s), `WithdrawalSheet` is presented automatically (~+1.8 s — see "Auto-sheet timing").
3. Sheet shows expected cash for *this Barkasse* (its full `cash_sales_since`, not just this tour's portion — see "Why full sum" below).
4. Counted-amount input is focused; user types the counted total, taps "Entnahme buchen".
5. Sheet dismisses; entry is created; `RefillSummaryView` is unchanged underneath; user taps "Done" as usual.

### C. After a refill tour (multiple Barkassen)

1. Tour completes; `RefillSummaryView` displays.
2. No auto-sheet. Above the existing "Done" button a new block appears:
   ```
   💶 Bargeld zur Entnahme:
   ─ Region Süd       €45,50   [→]
   ─ Region Nord      €33,00   [→]
   ```
3. Each `[→]` opens its `WithdrawalSheet` for that Barkasse. After dismiss, summary stays.

### D. After a refill tour (no Barkasse / no cash sales)

1. Tour completes; `RefillSummaryView` is identical to today. No block, no auto-sheet.

### E. Bank deposit from inside Cash Book

1. From Dashboard tile → push `CashBookView`.
2. Tap "Geld auf Bank einzahlen" CTA → `BankDepositSheet` modal.
3. Default amount empty; "Gesamten Bestand" quick-fill button writes `currentBalance` into the field.
4. Submit → entry created; sheet dismisses; flow card refreshes; tile auto-updates.

## Why full Barkasse sum, not tour-only

In flow B, the natural framing is "this tour brought in roughly €X". But the cash physically sitting at the machines today is `cash_sales_since_last_entry` — which can include money from earlier tours that wasn't booked yet, or money from passive sales between tours. The user counts whatever is in the cash drawer, not what they personally watched go in. The "Erwartet (max.)" framing established in the web (and the changer-hint italic) carries this honestly. Showing only the tour-portion would either undercount (when older money is also in the drawer) or require tracking per-tour state we don't have.

## Architecture

### Sidebar / Tab navigation

```swift
// Navigation/AppNavigation.swift
enum SidebarItem: String, ... {
    case dashboard, machines, refill, inbox,
         cashBook,                          // NEU
         products, warehouse, deals, settings

    var label: String {
        switch self {
        case .cashBook: "Kassenbuch"
        // ...
        }
    }

    var icon: String {
        switch self {
        case .cashBook: "banknote.fill"
        // ...
        }
    }

    var compactTab: AppTab? {
        switch self {
        case .cashBook: nil  // → "More"
        // ...
        }
    }
}
```

`SidebarNavigationView` and `CompactTabView` gain a `NavigationDestination` for `.cashBook → CashBookView()`.

### File layout

```
ios/VMflow/
├── Models/
│   └── CashBook.swift                NEW — CashBook, CashBookEntry, TheoreticalCash, CashBookEntryType, BarkasseSettings
├── ViewModels/
│   └── CashBookViewModel.swift       NEW — fetch, create entry, compute balances; @MainActor; provided to env
├── Views/CashBook/
│   ├── CashBookView.swift            NEW — main screen
│   ├── FlowVisualisationCard.swift   NEW — three stations + arrows (vertical-stacked, mobile-first)
│   ├── EntriesListSection.swift      NEW — list of CashBookEntry rows with type badge + amount + difference subline
│   ├── WithdrawalSheet.swift         NEW — modal sheet
│   ├── BankDepositSheet.swift        NEW — modal sheet
│   └── MultiBarkasseCashBlock.swift  NEW — inline list rendered on RefillSummaryView when ≥2 Barkassen have cash
└── Views/Dashboard/
    └── CashBookCard.swift            NEW — Mini-Flow tile
```

### Modified files

| File | Change |
|------|--------|
| `Navigation/AppNavigation.swift` | New `SidebarItem.cashBook` case + label + icon |
| `Navigation/SidebarNavigationView.swift` | NavigationDestination for `.cashBook` → `CashBookView()` |
| `Navigation/CompactTabView.swift` | Routing in the "More" subtree |
| `Views/Dashboard/DashboardView.swift` | Insert `CashBookCard` between top KPI cards and the sales list |
| `Views/Refill/RefillSummaryView.swift` | After-animation auto-sheet for single-Barkasse case; inline multi-Barkasse block |
| `ViewModels/RefillWizardViewModel.swift` | Computed properties: `barkassenForTour`, `expectedCashForBarkasse(id:)`, `singleBarkasseAutoSheetTarget` |
| `Navigation/AdaptiveRootView.swift` | `@StateObject private var cashBookVM = CashBookViewModel()` provider, attached via `.environmentObject(cashBookVM)` (see "Provider scope") |
| `Resources/Localizable.xcstrings` | New keys (de + en) per "Localization" section |

## Data Model

```swift
struct CashBook: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let companyId: UUID
    let name: String
    let initialBalance: Double
    let bankDepositThreshold: Double
    let trackPerMachine: Bool
    let isActive: Bool
    // NOTE: `activated_at` and `created_by` from the DB are intentionally
    // omitted — neither is surfaced in the iOS UI in this scope. Adding
    // them back is trivial when needed (decoder defaults to optional or
    // expand the CodingKeys).

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case companyId = "company_id"
        case name
        case initialBalance = "initial_balance"
        case bankDepositThreshold = "bank_deposit_threshold"
        case trackPerMachine = "track_per_machine"
        case isActive = "is_active"
    }
}

enum CashBookEntryType: String, Codable {
    case initial
    case withdrawal
    case correction
    case payout
    case reversal
}

struct CashBookEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let cashBookId: UUID
    let companyId: UUID
    let entryNumber: Int
    let type: CashBookEntryType
    let amount: Double
    let balanceAfter: Double
    let description: String?
    let machineId: UUID?
    let countedAmount: Double?
    let expectedAmount: Double?
    let correctsEntryId: UUID?
    let isReversed: Bool
    let createdBy: UUID
    let hash: String
    // CodingKeys map snake_case
}

struct TheoreticalCash: Codable, Hashable {
    let theoreticalBalance: Double
    let lastEntryBalance: Double
    let cashSalesSince: Double
    let lastEntryAt: Date
    let entryCount: Int
    let machines: [PerMachineCashSales]

    struct PerMachineCashSales: Codable, Hashable, Identifiable {
        var id: UUID { machineId }
        let machineId: UUID
        let machineName: String?
        let cashSales: Double
    }
    // CodingKeys map snake_case
}
```

## ViewModel Surface

```swift
@MainActor
final class CashBookViewModel: ObservableObject {
    // State
    @Published private(set) var cashBooks: [CashBook] = []
    @Published var selectedCashBookId: UUID?  // persisted via @AppStorage outside the VM
    @Published private(set) var entries: [CashBookEntry] = []
    @Published private(set) var theoreticalCash: TheoreticalCash?
    @Published private(set) var machinesByCashBook: [UUID: [VendingMachine]] = [:]  // for refill mapping
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingEntries = false
    @Published var error: String?

    // Computed
    var selectedCashBook: CashBook? { cashBooks.first { $0.id == selectedCashBookId } }
    var currentBalance: Double { entries.first?.balanceAfter ?? selectedCashBook?.initialBalance ?? 0 }
    var lastBankDeposit: CashBookEntry? {
        // entries is DESC by entry_number — same invariant as web
        entries.first { $0.type == .payout && !$0.isReversed }
    }

    // Loading
    func refresh() async                                // refresh cash_books + machines
    func loadEntries(for cashBookId: UUID) async        // load entries DESC
    func loadTheoreticalCash(for cashBookId: UUID) async

    // Mutations
    func recordWithdrawal(cashBookId: UUID, counted: Double, expected: Double, machineId: UUID?, description: String) async throws
    func recordBankDeposit(cashBookId: UUID, amount: Double, description: String) async throws

    // Refill helpers (used by RefillWizardViewModel)
    func barkassenForVisitedMachines(_ machineIds: Set<UUID>) -> [CashBook]
    func cashSalesSinceForCashBook(_ cashBookId: UUID) -> Double  // reads cached theoreticalCash; refreshes lazily
}
```

### Sign convention (CRITICAL — must match web exactly)

The DB trigger computes `balance_after = previous_balance + amount`. The web records:
- **Withdrawal** (`type = 'withdrawal'`): `amount` is **positive** — money flowing INTO the cash box from machines. `balance_after` increases.
- **Bank deposit** (`type = 'payout'`): `amount` is **negative** — money flowing OUT to the bank. `balance_after` decreases.

`recordWithdrawal` accepts `counted: Double` (absolute, positive) and inserts it as-is (positive sign).
`recordBankDeposit` accepts `amount: Double` (absolute, positive) and **negates internally** before insert. Callers always pass a non-negative `amount`; the VM is the only place that handles the sign.

Mismatching this would silently corrupt the GoBD hash chain semantics — the chain itself stays valid, but the running balance would diverge from web.

### Provider scope

`CashBookViewModel` is provided once at the **`AdaptiveRootView`** level (not `VMflowApp`), mirroring the existing pattern for auth-scoped services (`realtime`, `notificationService`). Rationale: the VM only makes sense after a user is logged in and an organisation is resolved; putting it at the App root would force special-casing the unauthenticated states.

```swift
// AdaptiveRootView.swift (modified)
struct AdaptiveRootView: View {
    @StateObject private var cashBookVM = CashBookViewModel()
    // ... existing services ...

    var body: some View {
        // ... existing content ...
            .environmentObject(cashBookVM)
    }
}
```

Consumers use `@EnvironmentObject var cashBookVM: CashBookViewModel`. The required injection points are:
- `CashBookView` (full screen)
- `CashBookCard` (dashboard tile)
- `WithdrawalSheet` and `BankDepositSheet` (when presented)
- `RefillSummaryView` (so the auto-sheet can present `WithdrawalSheet` correctly)
- `RefillWizardViewModel` reads from this VM via the SwiftUI environment-injection mechanism — see "Refill Integration" below for the exact handoff.

This keeps the existing per-view `@StateObject private var viewModel = XxxViewModel()` pattern for everything else (Products, Deals, Refill, Warehouse) untouched. (Implementer note: grep `AdaptiveRootView.swift` for existing `@StateObject` providers before placing the new one — confirm the file name/structure matches what's in the source tree at the time of implementation.)

## UI Components

### `FlowVisualisationCard`

Vertical-stacked layout (mobile-first; iPad keeps the same vertical stack — no horizontal layout because the iOS dashboard uses a single column):

```
┌─────────────────────────────────────┐
│ 🏪 In Automaten         €12,50      │
│   ▾ Büro 2.OG: +€7,00   (collapse)  │  optional per-machine breakdown
│   ▾ Lobby:     +€5,50              │
└──────────────────┬──────────────────┘
                   ▼
                [↓ Geld aus Automat entnehmen ]   ← primary green button
                   ▼
┌─────────────────────────────────────┐
│ 🧾 In der Kasse        €234,00      │
│ seit 15.04.2026                     │
└──────────────────┬──────────────────┘
                   ▼
                [🏦 Geld auf Bank einzahlen ]    ← secondary
                   ▼
┌─────────────────────────────────────┐
│ 🏦 Letzte Bankeinzahlung           │
│ €480,00 · vor 5 Tagen               │
└─────────────────────────────────────┘
```

The amber-pulse-ring rule from the web carries over:
- Withdraw CTA pulses when `theoreticalCash.cashSalesSince > 0`
- Bank-deposit CTA pulses when `currentBalance >= selectedCashBook.bankDepositThreshold`

### `WithdrawalSheet` API

```swift
struct WithdrawalSheet: View {
    let cashBook: CashBook
    let fromTour: Bool          // currently used only for analytics / future-proofing; the default description text is the same as web (`cash_book_default_withdrawal_desc`) regardless of origin to avoid divergence in the entries history
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var cashBookVM: CashBookViewModel
    // ... form @State and computed difference ...
}
```

The machine picker (only rendered when `cashBook.trackPerMachine == true`) reads its option list from `cashBookVM.machinesByCashBook[cashBook.id]`, falling back to an empty section if the map has no entry yet. The `EntriesListSection` resolves a row's `machineId` to a name via the same map (lookup helper on the VM: `func machineName(_ id: UUID?) -> String?`).

### `WithdrawalSheet`

```
┌─────────────────────────────────────┐
│ Geld aus Automat entnehmen      ✕  │
├─────────────────────────────────────┤
│ Erwartet (max., seit letzter Entn.) │
│ €78,50                              │
│   Büro 2.OG: +€45,00                │
│   Lobby:     +€33,50                │
│ ─                                   │
│ Der Münzwechsler kann Bargeld       │
│ zwischenspeichern – kleinere        │
│ Differenzen sind normal.            │
├─────────────────────────────────────┤
│ Gezählter Betrag (EUR)              │
│ ┌─────────────┐                     │
│ │  78.50      │  (focused, decimal) │
│ └─────────────┘                     │
│ Differenz: −€0,00                   │  (muted, only when nonzero)
├─────────────────────────────────────┤
│ Beschreibung                        │
│ Geldentnahme aus Automat            │  (or " (nach Tour)" suffix)
├─────────────────────────────────────┤
│ Aus welchem Automat? (optional)     │  (only if trackPerMachine == true
│ ▾ —                                 │   AND assignedMachines is non-empty)
├─────────────────────────────────────┤
│        [Abbrechen]  [Buchen]        │
└─────────────────────────────────────┘
```

Presented as `.sheet(isPresented:)`. Uses standard SwiftUI `Form` with sections to mirror the web modal's structure.

### `BankDepositSheet`

```
┌─────────────────────────────────────┐
│ Geld auf Bank einzahlen        ✕   │
├─────────────────────────────────────┤
│ Aktueller Kassenstand: €234,00      │
├─────────────────────────────────────┤
│ Betrag zur Bank (EUR)               │
│ ┌─────────────┐ [Gesamten Bestand]  │
│ │    234.00   │                     │
│ └─────────────┘                     │
├─────────────────────────────────────┤
│ Beschreibung                        │
│ Bankeinzahlung                      │
├─────────────────────────────────────┤
│      [Abbrechen]  [Einzahlung buchen]│
└─────────────────────────────────────┘
```

### `EntriesListSection`

A SwiftUI `List` section showing `CashBookEntry` rows DESC by `entryNumber`. Each row:
```
[Aus Automat]   +€45.00       08.05. 14:32
                Geldentnahme aus Automat
                Differenz: €2,00 (Gezählt: €43,00)   ← muted, only when applicable
                Lucien Kerl
```
Type badges use the same color palette as the web (red for withdrawal, blue for payout, etc.). No reverse button (web-only).

### `CashBookCard` (Dashboard)

```
┌─────────────────────────────────────┐
│ 💶 Kassenbuch                  ▸    │
├─────────────────────────────────────┤
│ In Automaten              €12,50    │
│ In der Kasse              €234,00   │
│ Letzte Bankeinzahlung   Vor 5 Tagen │
├─────────────────────────────────────┤
│ (optional) Bankeinzahlung empfohlen │  ← only if balance >= threshold
└─────────────────────────────────────┘
```

Whole card is tappable; pushes onto the current `NavigationStack` (the dashboard's nav stack — same pattern as `MachineCard` does today).

## Refill Integration

### Component layout

Two new view types live in `Views/CashBook/`:
- `WithdrawalSheet.swift` — already declared in "File layout"; API spelled out above.
- `MultiBarkasseCashBlock.swift` — Renders the inline list of Barkassen-with-cash on the Refill summary in the multi-Barkasse case. Props:
  ```swift
  struct MultiBarkasseCashBlock: View {
      let barkassen: [CashBook]
      let expectedCashFor: (UUID) -> Double   // closure into the VM (avoids passing the whole VM)
      let onSelect: (CashBook) -> Void
  }
  ```
  Call site in `RefillSummaryView`:
  ```swift
  MultiBarkasseCashBlock(
      barkassen: viewModel.barkassenWithCashFromTour,
      expectedCashFor: { id in cashBookVM.cashSalesSinceForCashBook(id) },
      onSelect: { autoSheetBarkasse = $0 }
  )
  ```

### Data preparation in `RefillWizardViewModel`

```swift
extension RefillWizardViewModel {
    /// Cash books whose machines were visited in this tour AND have cash_sales > 0.
    var barkassenWithCashFromTour: [CashBook] {
        let visited = Set(tourLog.map(\.machineId))
        let candidates = cashBookViewModel.barkassenForVisitedMachines(visited)
        return candidates.filter { cb in
            cashBookViewModel.cashSalesSinceForCashBook(cb.id) > 0.001
        }
    }

    /// If exactly one Barkasse with cash matches this tour, return it.
    var singleBarkasseAutoSheetTarget: CashBook? {
        let bs = barkassenWithCashFromTour
        return bs.count == 1 ? bs.first : nil
    }
}
```

### `RefillSummaryView` changes

```swift
struct RefillSummaryView: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    @EnvironmentObject var cashBookVM: CashBookViewModel
    @State private var showCheckmark = false
    @State private var showStats = false
    @State private var showButton = false
    @State private var autoSheetBarkasse: CashBook?  // drives the auto-sheet

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // ... existing animation, stats, "Done" button ...

                // Multi-Barkasse inline block (only when count >= 2)
                if viewModel.barkassenWithCashFromTour.count >= 2 {
                    MultiBarkasseCashBlock(
                        barkassen: viewModel.barkassenWithCashFromTour,
                        expectedCashFor: { id in cashBookVM.cashSalesSinceForCashBook(id) },
                        onSelect: { autoSheetBarkasse = $0 }
                    )
                }
            }
        }
        .sheet(item: $autoSheetBarkasse) { barkasse in
            WithdrawalSheet(cashBook: barkasse, fromTour: true)
                .environmentObject(cashBookVM)
        }
        .onAppear {
            // (existing +0.0 s and +0.4 s ticks elided — see Auto-sheet timing)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation { showButton = true }
            }
            // NEW tick — fires after Done button finishes fading in (~+1.7 s)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                if let target = viewModel.singleBarkasseAutoSheetTarget {
                    autoSheetBarkasse = target
                }
            }
        }
    }
}
```

### Auto-sheet timing

The existing `RefillSummaryView` schedules three animation ticks via `asyncAfter`:
- `+0.0 s` — checkmark scales up (0.6 s spring)
- `+0.4 s` — stats fade in (0.4 s easeOut)
- `+0.6 s` — Done button fades in with `.delay(0.7)` modifier (so it actually completes around `+1.7 s`)

The auto-sheet must fire **after the Done button has fully appeared** so the user perceives a clean "animation done → sheet slides up" sequence rather than a chaotic overlap. We add a fourth tick at `+1.8 s`:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
    if let target = viewModel.singleBarkasseAutoSheetTarget {
        autoSheetBarkasse = target
    }
}
```

If the user dismisses by swipe-down, `autoSheetBarkasse` becomes `nil` (via `.sheet(item:)` Binding) and the summary remains for "Done".

## Localization

New `Localizable.xcstrings` entries (DE + EN). Keys use `cash_book_*` snake-case for consistency with existing iOS pattern.

| Key | DE | EN |
|---|---|---|
| `cash_book_title` | Kassenbuch | Cash Book |
| `cash_book_in_machines` | In Automaten | In machines |
| `cash_book_in_box` | In der Kasse | In cash box |
| `cash_book_last_bank_deposit` | Letzte Bankeinzahlung | Last bank deposit |
| `cash_book_no_deposit_yet` | Noch keine | None yet |
| `cash_book_record_withdrawal` | Geld aus Automat entnehmen | Take cash from machine |
| `cash_book_record_payout` | Geld auf Bank einzahlen | Deposit to bank |
| `cash_book_book_entry` | Entnahme buchen | Book withdrawal |
| `cash_book_book_deposit` | Einzahlung buchen | Book deposit |
| `cash_book_full_amount` | Gesamten Bestand | Full amount |
| `cash_book_expected_max` | Erwartet (max., seit letzter Entnahme) | Expected (max., since last withdrawal) |
| `cash_book_changer_hint` | Der Münzwechsler kann Bargeld zwischenspeichern – kleinere Differenzen sind normal. | The coin changer can hold cash back — small differences are normal. |
| `cash_book_difference` | Differenz: %@ (Gezählt: %@) | Difference: %@ (Counted: %@) |
| `cash_book_after_tour_hint` | Bargeld zur Entnahme: | Cash to collect: |
| `cash_book_setup_in_web` | In der Web-App anlegen | Create in web app |
| `cash_book_counted_amount` | Gezählter Betrag (EUR) | Counted amount (EUR) |
| `cash_book_amount_to_bank` | Betrag zur Bank (EUR) | Amount to bank (EUR) |
| `cash_book_description` | Beschreibung | Description |
| `cash_book_current_balance` | Aktueller Kassenstand | Current balance |
| `cash_book_from_machine` | Aus welchem Automat? (optional) | From which machine? (optional) |
| `cash_book_deposit_recommended` | Bankeinzahlung empfohlen | Bank deposit recommended |
| `cash_book_since_date` | seit %@ | since %@ |
| `cash_book_ago_days` | Vor %lld Tagen *(use xcstrings plural variants for `one`/`other`)* | %lld days ago *(plural-aware)* |
| `cash_book_today` | Heute | Today |
| `cash_book_type_initial` | Anfangsbestand | Initial balance |
| `cash_book_type_withdrawal` | Aus Automat | From machine |
| `cash_book_type_correction` | Korrektur | Correction |
| `cash_book_type_payout` | Bankeinzahlung | Bank deposit |
| `cash_book_type_reversal` | Storno | Reversal |
| `cash_book_default_withdrawal_desc` | Geldentnahme aus Automat | Cash withdrawal from machine |
| `cash_book_default_deposit_desc` | Bankeinzahlung | Bank deposit |
| `cash_book_no_barkasse_yet` | Noch keine Barkasse vorhanden | No cash book yet |

## Persistence & Lifecycle

- `selectedCashBookId` is persisted via `@AppStorage("selected_barkasse_id")` (string UUID) outside the VM, restored on cold launch.
- On `CashBookViewModel.refresh()`, post-fetch reconciliation runs in this order:
  1. **`cashBooks.isEmpty`** → set `selectedCashBookId = nil` (do NOT keep a stale UUID).
  2. **Stored ID still in `cashBooks`** → keep selection.
  3. **Stored ID gone (Barkasse deleted on web)** → fall back to first Barkasse alphabetically by name.
  4. **Stored ID is `nil` AND `cashBooks.count == 1`** → auto-select that single Barkasse (matches the web composable's `fetchCashBooks` behaviour, where a single Barkasse is auto-selected on first load).
  5. **Stored ID is `nil` AND `cashBooks.count >= 2`** → leave `nil`. The dashboard tile shows the empty-state hint, the full screen shows a Barkasse picker. Web matches this exactly.
- **First Barkasse created on web while iOS is in foreground** → handled by step 4 on the next `refresh()` (foreground triggers refresh, see below). The user sees the new Barkasse auto-selected on their next pull-to-refresh / next foreground transition.
- `entries` are not persisted to disk — fetched on demand when a Barkasse is selected.
- `theoreticalCash` is fetched lazily: on `CashBookView.onAppear`, on `CashBookCard.onAppear` (dashboard), and explicitly before opening `WithdrawalSheet`.
- `applicationWillEnterForeground` triggers `cashBookVM.refresh()` (existing pattern in `WarehouseViewModel.swift`).

## Backward Compatibility

- **No DB schema changes**, no migrations, no new edge functions. The app uses `cash_books`, `cash_book_entries`, `vendingMachine`, and the `get_theoretical_cash` RPC exactly as the web does today.
- **No firmware changes**. The cash book is a software-only feature.
- **GoBD hash chain stays intact**: every `cash_book_entries` insert from iOS goes through the same trigger pipeline as web inserts. Hash, balance_after, and entry_number are computed by the BEFORE INSERT trigger.
- **Web continues to work**: iOS and web read/write the same tables. If both are open and someone records on web, iOS sees it on next refresh; same for the other direction.
- **Existing iOS users without Barkasse**: dashboard tile shows the empty-state ("In der Web-App anlegen"), sidebar entry takes them to the same empty-state on the full screen. No crashes, no required setup.

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Two clients (web + iOS) write entries within the same second → trigger sees the same prior hash → entry_number collision via `UNIQUE(cash_book_id, entry_number)` | The `before_insert_cash_book_entry` trigger uses `SELECT ... FOR UPDATE` on the `cash_books` row (already in place from the original cash-book migration). Postgres serializes the inserts; one wins the lock, the other waits and reads the new prior hash. No iOS-side change needed. |
| `selectedCashBookId` from `@AppStorage` references a deleted Barkasse | On `refresh()`, validate the ID against `cashBooks`; fall back to first alphabetically. |
| Auto-sheet timing collides with the existing summary animation | Trigger in a new `asyncAfter(deadline: .now() + 1.8)` block — fires after the Done-button reveal completes (~+1.7 s). See "Auto-sheet timing". |
| User dismisses auto-sheet by swipe-down without booking | Acceptable. They can later open the sheet via dashboard tile or sidebar. No persistent reminder; the dashboard pulse is the soft hint. |
| Refill tour visits machines from many Barkassen → inline block becomes long | Limit visible inline rows to 3, with a "Alle anzeigen" disclosure. (Practical limit — most operators have 1-2 Barkassen total.) |
| Decimal input on iOS keyboard ignores user's locale | Use `TextField` with `.keyboardType(.decimalPad)`, parse with `NumberFormatter` in `.currency` style and locale `Locale.current`. Same approach used by `ManualSaleView`. |
| `CashBookViewModel` not provided to a downstream view | We wire it once in `AdaptiveRootView` (see "Provider scope") so coverage is uniform; SwiftUI surfaces a runtime crash at the missing `@EnvironmentObject` site if a consumer is added without an injection point. |
| iOS reads stale `theoreticalCash` between machine assignment changes (web side) | Pull-to-refresh + foreground-refresh covers this. The "real" value is always one tap away. Background invalidation is out of scope. |

## Build Order

1. **Models** (`Models/CashBook.swift`) — add `CashBook`, `CashBookEntry`, `CashBookEntryType`, `TheoreticalCash` with snake_case `CodingKeys`.
2. **ViewModel** (`ViewModels/CashBookViewModel.swift`) — `@MainActor`-isolated, fetch and create methods, computed `currentBalance` / `lastBankDeposit`. Wire as `@StateObject` in `AdaptiveRootView` and inject via `.environmentObject(cashBookVM)` (see "Provider scope").
3. **Localization** — add all `cash_book_*` keys to `Resources/Localizable.xcstrings` (DE + EN) so subsequent UI work has them.
4. **Building blocks** — `Views/CashBook/FlowVisualisationCard.swift` (with three station sub-views inline), `Views/CashBook/EntriesListSection.swift`. No mutating actions yet.
5. **Sheets** — `WithdrawalSheet.swift`, `BankDepositSheet.swift`. Each owns its form state, calls VM mutation, dismisses on success.
6. **Main screen** — `CashBookView.swift` composing flow card + CTAs + entries list. Pull-to-refresh.
7. **Dashboard tile** — `CashBookCard.swift`; insert into `DashboardView` between top KPIs and sales list. Tap → push `CashBookView`.
8. **Sidebar wiring** — extend `SidebarItem`, add `NavigationDestination` cases in `SidebarNavigationView` and `CompactTabView`.
9. **Refill integration** — extend `RefillWizardViewModel` with `barkassenWithCashFromTour` and `singleBarkasseAutoSheetTarget`. Update `RefillSummaryView` for auto-sheet (single) and inline block (multi).
10. **Smoke test** — fresh sim, log in, navigate sidebar → Cash Book; create entry from sheet; verify dashboard tile updates; run a refill tour against a machine assigned to a Barkasse; verify auto-sheet pops and entry persists; verify multi-Barkasse inline block renders when applicable.

## Open Questions (Resolved during brainstorming)

- **Multi-Barkasse auto-sheet behaviour** → Skip auto, show inline block per Barkasse (option C from brainstorming).
- **Dashboard tile content** → Three values, mini-flow style (option α from brainstorming).
- **Sidebar entry vs. tile-only access** → Add to sidebar (option ii); placement between `inbox` and `products`.
- **Tour-portion vs. full-Barkasse "Erwartet"** → Show full Barkasse `cash_sales_since` (already established in web).
- **No-Barkasse / zero-cash logic** → No auto-sheet, no inline block, no Dashboard pulse. Tile shows empty-state hint.

## Out of Scope (Future)

- Push notification when balance crosses bankDepositThreshold (would replace the pulse).
- Local biometric auth on the WithdrawalSheet (overkill for current threat model).
- Inline correction/storno without web round-trip (separate UX project).
- Real-time sync via Supabase channels.
- Apple Wallet pass for the cash book balance (we're not joking, but it's out of scope).

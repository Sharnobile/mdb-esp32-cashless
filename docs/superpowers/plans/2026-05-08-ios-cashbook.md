# iOS Kassenbuch (Mid-Scope) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the Kassenbuch web feature to the iOS native app at mid-scope (read-only views + the two cash-flow actions), with a dashboard tile and an auto-sheet that fires after a refill tour for the single-Barkasse case.

**Architecture:** Pure iOS frontend feature. No DB or backend changes. New SwiftUI views under `Views/CashBook/`, one new `@MainActor` `ObservableObject` (`CashBookViewModel`) provided from `AdaptiveRootView` and consumed via `@EnvironmentObject`. Reads/writes existing tables and RPCs through `SupabaseService.shared.client`. The GoBD hash-chain trigger (`before_insert_cash_book_entry`) on the DB serializes inserts from web + iOS — no client-side coordination needed.

**Tech Stack:** Swift 5.9 / SwiftUI / Combine, iOS 17+, supabase-swift 2.x, MVVM pattern with `@MainActor`-isolated ObservableObject ViewModels.

**Spec:** [docs/superpowers/specs/2026-05-08-ios-cashbook-design.md](../specs/2026-05-08-ios-cashbook-design.md)

**Verification model:** No automated test target exists for the iOS app (the codebase pattern is Xcode/simulator smoke tests). Each chunk ends with explicit smoke-test steps. Build verification via Xcode (⌘B) or `xcodebuild build` — no test runner.

---

## Pre-flight

- [ ] **Step 0.1: Open the iOS project**

```bash
open /Users/lucienkerl/Development/mdb-esp32-cashless/ios/VMflow.xcodeproj
```

Pick a simulator (iPhone 15 Pro or any iOS 17+). Build & run (⌘R) to confirm the baseline app launches and you can log in (test credentials in `memory/user_dev_credentials.md`). Navigate the existing tabs — Dashboard, Machines, Refill, Inbox, More → Settings — to confirm nothing is broken on `main` before changes.

- [ ] **Step 0.2: Confirm prerequisites in the local DB**

```bash
docker exec supabase_db_supabase-test psql -U postgres -d postgres \
  -c "SELECT name, bank_deposit_threshold, track_per_machine FROM cash_books;"
```

Expected: at least one row. If empty, create one through the web UI (`http://localhost:3000/cash-book` → "Neue Barkasse"). Verify at least one machine is assigned to it (`vendingMachine.cash_book_id` set) so the Refill integration can be smoke-tested at the end.

- [ ] **Step 0.3: Sanity-check the Supabase service surface**

Open `ios/VMflow/Services/SupabaseService.swift` and confirm:
- `static let shared = SupabaseService()` exists (line ~30)
- `private(set) var client: SupabaseClient` is the publicly readable client (line ~33)
- `client.from("…")` and `client.rpc("…")` are the standard call surfaces (used by every existing ViewModel — verify by grepping `WarehouseViewModel.swift` for `client.from`)

You'll use `SupabaseService.shared.client` in the new ViewModel exactly the same way `WarehouseViewModel` does. No service changes are required.

---

## Chunk 1: Foundation (Models + ViewModel + Localization)

Establishes the data layer and translation strings. Nothing visible in the UI yet — all subsequent chunks depend on this.

### Task 1: Models

**Files:**
- Create: `ios/VMflow/Models/CashBook.swift`

- [ ] **Step 1.1: Create the model file**

Create `ios/VMflow/Models/CashBook.swift` with the full content:

```swift
import Foundation

// MARK: - CashBook

struct CashBook: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let companyId: UUID
    let name: String
    let initialBalance: Double
    let bankDepositThreshold: Double
    let trackPerMachine: Bool
    let isActive: Bool

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

// MARK: - CashBookEntry

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

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case cashBookId = "cash_book_id"
        case companyId = "company_id"
        case entryNumber = "entry_number"
        case type
        case amount
        case balanceAfter = "balance_after"
        case description
        case machineId = "machine_id"
        case countedAmount = "counted_amount"
        case expectedAmount = "expected_amount"
        case correctsEntryId = "corrects_entry_id"
        case isReversed = "is_reversed"
        case createdBy = "created_by"
        case hash
    }
}

// MARK: - TheoreticalCash (RPC payload)

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

        enum CodingKeys: String, CodingKey {
            case machineId = "machine_id"
            case machineName = "machine_name"
            case cashSales = "cash_sales"
        }
    }

    enum CodingKeys: String, CodingKey {
        case theoreticalBalance = "theoretical_balance"
        case lastEntryBalance = "last_entry_balance"
        case cashSalesSince = "cash_sales_since"
        case lastEntryAt = "last_entry_at"
        case entryCount = "entry_count"
        case machines
    }
}

// MARK: - VendingMachine row used for cash-book wiring

/// A trimmed projection of `vendingMachine` that the cash-book layer needs.
/// Keeps the existing `Models/VendingMachine.swift` (used by the Machines feature)
/// untouched — that one has the full set of fields and a different `Codable`
/// shape. We use a separate, focused projection here to avoid coupling the two.
struct CashBookMachineRef: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String?
    let cashBookId: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case cashBookId = "cash_book_id"
    }
}
```

- [ ] **Step 1.2: Add the file to the Xcode target**

The project uses xcodegen (`project.yml`). After creating the file, regenerate the project:

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
xcodegen generate
```

Confirm the file appears in the Xcode navigator under `Models/`.

If `xcodegen` is not installed: `brew install xcodegen`. If you'd rather drag the file into Xcode manually, that works too — but `xcodegen generate` is the project's source-of-truth approach.

- [ ] **Step 1.3: Build to verify**

In Xcode, ⌘B. Expected: build succeeds with zero warnings related to `CashBook.swift`.

- [ ] **Step 1.4: Commit**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless
git add ios/VMflow/Models/CashBook.swift ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): add CashBook, CashBookEntry, TheoreticalCash, CashBookMachineRef models"
```

### Task 2: ViewModel

**Files:**
- Create: `ios/VMflow/ViewModels/CashBookViewModel.swift`

- [ ] **Step 2.1: Create the ViewModel file**

Create `ios/VMflow/ViewModels/CashBookViewModel.swift`:

```swift
import Foundation
import Supabase

/// Drives the Cash Book feature: list + entries + theoretical cash + writes.
@MainActor
final class CashBookViewModel: ObservableObject {
    // MARK: - Published State

    @Published private(set) var cashBooks: [CashBook] = []
    @Published var selectedCashBookId: UUID?
    @Published private(set) var entries: [CashBookEntry] = []
    @Published private(set) var theoreticalCash: TheoreticalCash?
    @Published private(set) var machines: [CashBookMachineRef] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingEntries = false
    @Published var error: String?

    private let client = SupabaseService.shared.client

    // Persisted across launches via @AppStorage in AdaptiveRootView; we just
    // read/write through `selectedCashBookId` and let the view layer wire the
    // @AppStorage.
    private static let appStorageKey = "selected_barkasse_id"

    // MARK: - Computed

    var selectedCashBook: CashBook? {
        cashBooks.first { $0.id == selectedCashBookId }
    }

    /// Latest balance: first entry (DESC by entry_number) wins.
    var currentBalance: Double {
        entries.first?.balanceAfter ?? selectedCashBook?.initialBalance ?? 0
    }

    /// Most recent non-reversed payout. Invariant: `entries` is sorted DESC
    /// by `entry_number`, so the first match is the most recent one.
    var lastBankDeposit: CashBookEntry? {
        entries.first { $0.type == .payout && !$0.isReversed }
    }

    var machinesForSelectedCashBook: [CashBookMachineRef] {
        guard let id = selectedCashBookId else { return [] }
        return assignedMachines(for: id)
    }

    /// Returns machines assigned to the given cash book. Used by sheets
    /// that may be opened for a Barkasse different from `selectedCashBookId`
    /// (e.g. from the multi-Barkasse refill block).
    func assignedMachines(for cashBookId: UUID) -> [CashBookMachineRef] {
        machines.filter { $0.cashBookId == cashBookId }
    }

    // MARK: - Loading

    /// Fetches cash_books + machines in parallel, then reconciles selectedCashBookId.
    /// Spec §"Persistence & Lifecycle" enumerates the 5 reconciliation cases.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let booksTask: [CashBook] = client
                .from("cash_books")
                .select("*")
                .order("name")
                .execute()
                .value

            async let machinesTask: [CashBookMachineRef] = client
                .from("vendingMachine")
                .select("id, name, cash_book_id")
                .execute()
                .value

            let (books, machines) = try await (booksTask, machinesTask)
            self.cashBooks = books
            self.machines = machines
            reconcileSelection()

            // If we now have a selection, load its entries + theoretical cash
            if let id = selectedCashBookId {
                await loadEntries(for: id)
                await loadTheoreticalCash(for: id)
            }
        } catch is CancellationError {
            // SwiftUI cancels refreshable tasks routinely — silent
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reconcileSelection() {
        // Spec §"Persistence & Lifecycle" — 5 cases, in order:
        // 1. cashBooks empty → nil
        if cashBooks.isEmpty {
            selectedCashBookId = nil
            return
        }
        // 2. stored ID still in cashBooks → keep
        if let id = selectedCashBookId, cashBooks.contains(where: { $0.id == id }) {
            return
        }
        // 3. stored ID gone → first alphabetically
        if selectedCashBookId != nil {
            selectedCashBookId = cashBooks.first?.id
            return
        }
        // 4. nil AND single Barkasse → auto-select
        if cashBooks.count == 1 {
            selectedCashBookId = cashBooks.first?.id
            return
        }
        // 5. nil AND multiple → leave nil (user must pick)
    }

    func loadEntries(for cashBookId: UUID) async {
        isLoadingEntries = true
        defer { isLoadingEntries = false }
        do {
            let result: [CashBookEntry] = try await client
                .from("cash_book_entries")
                .select("*")
                .eq("cash_book_id", value: cashBookId)
                .order("entry_number", ascending: false)
                .execute()
                .value
            self.entries = result
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// One-shot fetch of theoretical cash for a specific Barkasse.
    /// Does NOT mutate `theoreticalCash`. Returns nil on error or when the
    /// RPC has nothing to say (no entries yet). Used by callers that need
    /// data for a Barkasse that is NOT `selectedCashBookId` (e.g. the
    /// multi-Barkasse refill block, or a `WithdrawalSheet` opened for
    /// a non-selected Barkasse).
    func fetchTheoreticalCash(for cashBookId: UUID) async -> TheoreticalCash? {
        guard let book = cashBooks.first(where: { $0.id == cashBookId }) else { return nil }
        struct Params: Encodable {
            let p_cash_book_id: UUID
            let p_company_id: UUID
        }
        do {
            let result: TheoreticalCash = try await client
                .rpc("get_theoretical_cash", params: Params(p_cash_book_id: cashBookId, p_company_id: book.companyId))
                .execute()
                .value
            return result
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    /// Loads theoretical cash for the *currently selected* Barkasse and
    /// writes it to the published `theoreticalCash` value. No-op if
    /// `cashBookId` does not match `selectedCashBookId` — for non-selected
    /// Barkassen, callers should use `fetchTheoreticalCash(for:)` instead
    /// to avoid clobbering app-wide state.
    func loadTheoreticalCash(for cashBookId: UUID) async {
        guard cashBookId == selectedCashBookId else { return }
        self.theoreticalCash = await fetchTheoreticalCash(for: cashBookId)
    }

    // MARK: - Mutations

    /// Records a withdrawal (cash flowing INTO the box from machines).
    /// `counted` is the gezählter Betrag (positive). Sign convention spec'd:
    /// withdrawals are stored as positive `amount`.
    func recordWithdrawal(
        cashBookId: UUID,
        counted: Double,
        expected: Double,
        machineId: UUID?,
        description: String
    ) async throws {
        guard let companyId = cashBooks.first(where: { $0.id == cashBookId })?.companyId,
              let userId = client.auth.currentUser?.id else {
            throw CashBookError.notAuthenticated
        }

        struct Insert: Encodable {
            let cash_book_id: UUID
            let company_id: UUID
            let type: String
            let amount: Double
            let description: String?
            let machine_id: UUID?
            let counted_amount: Double?
            let expected_amount: Double?
            let created_by: UUID
        }

        let row = Insert(
            cash_book_id: cashBookId,
            company_id: companyId,
            type: "withdrawal",
            amount: counted,                     // POSITIVE — money INTO the box
            description: description,
            machine_id: machineId,
            counted_amount: counted,
            expected_amount: expected,
            created_by: userId
        )

        try await client.from("cash_book_entries").insert(row).execute()

        // Refresh local state
        await loadEntries(for: cashBookId)
        await loadTheoreticalCash(for: cashBookId)
    }

    /// Records a bank deposit (cash flowing OUT of the box to the bank).
    /// Caller passes a non-negative `amount`; we negate internally so the
    /// running balance decreases (matches web sign convention exactly).
    func recordBankDeposit(
        cashBookId: UUID,
        amount: Double,
        description: String
    ) async throws {
        guard let companyId = cashBooks.first(where: { $0.id == cashBookId })?.companyId,
              let userId = client.auth.currentUser?.id else {
            throw CashBookError.notAuthenticated
        }

        struct Insert: Encodable {
            let cash_book_id: UUID
            let company_id: UUID
            let type: String
            let amount: Double
            let description: String?
            let created_by: UUID
        }

        let row = Insert(
            cash_book_id: cashBookId,
            company_id: companyId,
            type: "payout",
            amount: -abs(amount),                 // NEGATIVE — money OUT of the box
            description: description,
            created_by: userId
        )

        try await client.from("cash_book_entries").insert(row).execute()

        await loadEntries(for: cashBookId)
        await loadTheoreticalCash(for: cashBookId)
    }

    // MARK: - Refill helpers

    /// Returns the cash books whose machines were visited in this set.
    func barkassenForVisitedMachines(_ machineIds: Set<UUID>) -> [CashBook] {
        let bookIds: Set<UUID> = Set(
            machines
                .filter { $0.cashBookId != nil && machineIds.contains($0.id) }
                .compactMap { $0.cashBookId }
        )
        return cashBooks.filter { bookIds.contains($0.id) }
    }

    /// Reads the most recent theoretical cash for a specific Barkasse.
    /// Triggers a refresh if the cached value is for a different Barkasse.
    func cashSalesSinceForCashBook(_ cashBookId: UUID) -> Double {
        // If theoreticalCash is for the requested book, use it directly.
        // Otherwise return 0 — the caller is expected to refresh first.
        if selectedCashBookId == cashBookId, let tc = theoreticalCash {
            return tc.cashSalesSince
        }
        return 0
    }

    /// Resolve a machine ID to a name for display.
    func machineName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return machines.first(where: { $0.id == id })?.name
    }
}

// MARK: - Errors

enum CashBookError: LocalizedError {
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated"
        }
    }
}
```

- [ ] **Step 2.2: Wire @AppStorage for `selectedCashBookId` in AdaptiveRootView (provider + persistence)**

Open `ios/VMflow/Navigation/AdaptiveRootView.swift`. Replace it with:

```swift
import SwiftUI

/// Routes between compact tab layout (iPhone) and sidebar layout (iPad/Mac)
/// based on horizontal size class.
struct AdaptiveRootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @EnvironmentObject var auth: AuthService
    @StateObject private var realtime = RealtimeService.shared
    @StateObject private var notificationService = NotificationService.shared
    @StateObject private var cashBookVM = CashBookViewModel()
    @AppStorage("selected_barkasse_id") private var selectedBarkasseIDRaw: String = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if sizeClass == .compact {
                CompactTabView()
            } else {
                SidebarNavigationView()
            }
        }
        .environmentObject(realtime)
        .environmentObject(cashBookVM)
        .task {
            realtime.start()
            await NotificationService.shared.setupAfterLogin()

            // Restore persisted selection, then refresh
            if let uuid = UUID(uuidString: selectedBarkasseIDRaw) {
                cashBookVM.selectedCashBookId = uuid
            }
            await cashBookVM.refresh()
            // Persist post-reconciliation
            selectedBarkasseIDRaw = cashBookVM.selectedCashBookId?.uuidString ?? ""
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await NotificationService.shared.refreshBadge()
                    await cashBookVM.refresh()
                    selectedBarkasseIDRaw = cashBookVM.selectedCashBookId?.uuidString ?? ""
                }
            }
        }
        .onChange(of: cashBookVM.selectedCashBookId) { _, newValue in
            selectedBarkasseIDRaw = newValue?.uuidString ?? ""
        }
    }
}
```

- [ ] **Step 2.3: Regenerate Xcode project + build**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
xcodegen generate
```

In Xcode: ⌘B. Expected: succeeds with zero warnings. The unused `cashBookVM` `@StateObject` will trigger a "declared but never used" warning *if* you also haven't added the env injection — but the code above injects it, so no warning expected.

- [ ] **Step 2.4: Verify the VM connects in a smoke test**

Add temporary logging at the end of `refresh()`:
```swift
#if DEBUG
print("[CashBookVM] refresh OK — books=\(cashBooks.count), selected=\(selectedCashBookId?.uuidString ?? "nil")")
#endif
```

Run the app (⌘R), log in. Watch the Xcode console. Expected log line within ~2 s of login:
```
[CashBookVM] refresh OK — books=1, selected=<uuid>
```

If `books=0`, you don't have a Barkasse in the local DB yet — go back to Pre-flight 0.2.

Remove the debug log before committing.

- [ ] **Step 2.5: Commit**

```bash
git add ios/VMflow/ViewModels/CashBookViewModel.swift \
        ios/VMflow/Navigation/AdaptiveRootView.swift \
        ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): add CashBookViewModel with @AppStorage selection persistence"
```

### Task 3: Localization

**Files:**
- Modify: `ios/VMflow/Resources/Localizable.xcstrings`

- [ ] **Step 3.1: Add cash book strings to xcstrings**

Open `ios/VMflow/Resources/Localizable.xcstrings` in Xcode (it has a custom string-catalog editor). Add the following keys (each row = one entry; for each key, fill DE and EN columns):

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
| `cash_book_today` | Heute | Today |
| `cash_book_type_initial` | Anfangsbestand | Initial balance |
| `cash_book_type_withdrawal` | Aus Automat | From machine |
| `cash_book_type_correction` | Korrektur | Correction |
| `cash_book_type_payout` | Bankeinzahlung | Bank deposit |
| `cash_book_type_reversal` | Storno | Reversal |
| `cash_book_default_withdrawal_desc` | Geldentnahme aus Automat | Cash withdrawal from machine |
| `cash_book_default_deposit_desc` | Bankeinzahlung | Bank deposit |
| `cash_book_no_barkasse_yet` | Noch keine Barkasse vorhanden | No cash book yet |
| `cash_book_book` | Buchen | Book |
| `cash_book_cancel` | Abbrechen | Cancel |
| `cash_book_done` | Fertig | Done |

For the plural-aware "vor X Tagen" / "X days ago" string:

- Add key `cash_book_ago_days` with type "Plural"
- DE: `one`: "Vor %lld Tag", `other`: "Vor %lld Tagen"
- EN: `one`: "%lld day ago", `other`: "%lld days ago"

> **Tip:** Right-click in the xcstring editor → "New Plural Variation" to switch the entry to the plural format.

- [ ] **Step 3.2: Build**

⌘B. Expected: success. The xcstrings file regenerates its strings table automatically.

- [ ] **Step 3.3: Commit**

```bash
git add ios/VMflow/Resources/Localizable.xcstrings
git commit -m "feat(ios): add Kassenbuch localized strings (de + en)"
```

---

## Chunk 2: Building Blocks (FlowVisualisationCard + EntriesListSection)

Two reusable views consumed by both the main screen and the dashboard tile (FlowVisualisationCard) / main screen alone (EntriesListSection).

### Task 4: FlowVisualisationCard

**Files:**
- Create: `ios/VMflow/Views/CashBook/FlowVisualisationCard.swift`

- [ ] **Step 4.1: Create the file with the full content**

```swift
import SwiftUI

/// Three-station vertical flow: In Automaten → In der Kasse → Letzte Bankeinzahlung.
/// Used on both the full Cash Book screen and the dashboard tile (with `compact = true`).
struct FlowVisualisationCard: View {
    let theoreticalCash: TheoreticalCash?
    let currentBalance: Double
    let lastBankDeposit: CashBookEntry?
    let bankDepositThreshold: Double
    /// When true, render the three station rows but suppress the action buttons.
    let compact: Bool
    let onWithdraw: (() -> Void)?
    let onDeposit: (() -> Void)?

    init(
        theoreticalCash: TheoreticalCash?,
        currentBalance: Double,
        lastBankDeposit: CashBookEntry?,
        bankDepositThreshold: Double,
        compact: Bool = false,
        onWithdraw: (() -> Void)? = nil,
        onDeposit: (() -> Void)? = nil
    ) {
        self.theoreticalCash = theoreticalCash
        self.currentBalance = currentBalance
        self.lastBankDeposit = lastBankDeposit
        self.bankDepositThreshold = bankDepositThreshold
        self.compact = compact
        self.onWithdraw = onWithdraw
        self.onDeposit = onDeposit
    }

    private var withdrawalNeeded: Bool {
        (theoreticalCash?.cashSalesSince ?? 0) > 0.001
    }

    private var depositRecommended: Bool {
        currentBalance >= bankDepositThreshold
    }

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            stationRow(
                icon: "storefront.fill",
                title: "cash_book_in_machines",
                amount: theoreticalCash?.cashSalesSince ?? 0,
                subtitle: machineBreakdownSubtitle
            )

            if !compact {
                arrowAndButton(
                    isPrimary: true,
                    label: "cash_book_record_withdrawal",
                    pulse: withdrawalNeeded,
                    action: onWithdraw
                )
            } else {
                arrow()
            }

            stationRow(
                icon: "tray.fill",
                title: "cash_book_in_box",
                amount: currentBalance,
                subtitle: lastEntrySubtitle
            )

            if !compact {
                arrowAndButton(
                    isPrimary: false,
                    label: "cash_book_record_payout",
                    pulse: depositRecommended,
                    action: onDeposit
                )
            } else {
                arrow()
            }

            stationRow(
                icon: "building.columns.fill",
                title: "cash_book_last_bank_deposit",
                amount: lastBankDeposit.map { abs($0.amount) },
                subtitle: lastDepositSubtitle
            )
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func stationRow(icon: String, title: LocalizedStringKey, amount: Double?, subtitle: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                if let s = subtitle {
                    Text(s).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Group {
                if let amount {
                    Text(amount, format: .currency(code: "EUR"))
                        .monospacedDigit()
                        .font(.title3.weight(.semibold))
                } else {
                    Text("cash_book_no_deposit_yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(.regularMaterial)
        }
    }

    @ViewBuilder
    private func arrow() -> some View {
        Image(systemName: "arrow.down")
            .foregroundStyle(.tertiary)
            .font(.callout)
    }

    @ViewBuilder
    private func arrowAndButton(
        isPrimary: Bool,
        label: LocalizedStringKey,
        pulse: Bool,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 6) {
            arrow()
            Button(action: { action?() }) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(isPrimary ? .green : .accentColor)
            .controlSize(.regular)
            .overlay(alignment: .center) {
                if pulse {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.orange.opacity(0.6), lineWidth: 2)
                        .padding(-2)
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
                }
            }
            arrow()
        }
        .disabled(action == nil)
    }

    // MARK: - Subtitle composition

    private var machineBreakdownSubtitle: String? {
        guard let machines = theoreticalCash?.machines, !machines.isEmpty else { return nil }
        let lines = machines.map { m in
            let formatted = NumberFormatter.localizedString(from: m.cashSales as NSNumber, number: .currency)
            return "\(m.machineName ?? "—") +\(formatted)"
        }
        return lines.joined(separator: " · ")
    }

    private var lastEntrySubtitle: String? {
        guard let date = theoreticalCash?.lastEntryAt else { return nil }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        let dateString = f.string(from: date)
        return String(format: NSLocalizedString("cash_book_since_date", comment: ""), dateString)
    }

    private var lastDepositSubtitle: String? {
        guard let entry = lastBankDeposit else { return nil }
        let days = Calendar.current.dateComponents([.day], from: entry.createdAt, to: Date()).day ?? 0
        if days == 0 {
            return NSLocalizedString("cash_book_today", comment: "")
        }
        return String(format: NSLocalizedString("cash_book_ago_days", comment: ""), days)
    }
}
```

- [ ] **Step 4.2: Regenerate project + build**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
xcodegen generate
```

⌘B. Expected: succeeds. No usage warnings — the view will be referenced by Chunk 3 onwards.

- [ ] **Step 4.3: Commit**

```bash
git add ios/VMflow/Views/CashBook/FlowVisualisationCard.swift \
        ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): add FlowVisualisationCard component"
```

### Task 5: EntriesListSection

**Files:**
- Create: `ios/VMflow/Views/CashBook/EntriesListSection.swift`

- [ ] **Step 5.1: Create the file**

```swift
import SwiftUI

/// Renders a list of CashBookEntry rows, grouped by date, with type badge,
/// amount, balance, optional difference subline, and machine name.
struct EntriesListSection: View {
    let entries: [CashBookEntry]
    let machineName: (UUID?) -> String?

    var body: some View {
        if entries.isEmpty {
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            ForEach(entries) { entry in
                row(for: entry)
            }
        }
    }

    @ViewBuilder
    private func row(for entry: CashBookEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                typeBadge(entry.type, reversed: entry.isReversed)
                Spacer()
                Text(formatAmount(entry.amount))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(entry.amount >= 0 ? Color.green : Color.red)
                Text(entry.balanceAfter, format: .currency(code: "EUR"))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 60, alignment: .trailing)
            }

            HStack {
                Text(entry.createdAt, format: .dateTime.day().month(.twoDigits).hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text(entry.description ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Optional subline: difference (counted vs expected)
            if let counted = entry.countedAmount,
               let expected = entry.expectedAmount,
               abs(counted - expected) > 0.001 {
                Text(differenceText(diff: abs(counted - expected), counted: counted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Optional subline: machine name
            if let mid = entry.machineId, let name = machineName(mid) {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .opacity(entry.isReversed ? 0.5 : 1)
    }

    @ViewBuilder
    private func typeBadge(_ type: CashBookEntryType, reversed: Bool) -> some View {
        let labelKey: LocalizedStringKey
        let color: Color
        switch type {
        case .initial:     labelKey = "cash_book_type_initial";     color = .gray
        case .withdrawal:  labelKey = "cash_book_type_withdrawal";  color = .red
        case .correction:  labelKey = "cash_book_type_correction";  color = .yellow
        case .payout:      labelKey = "cash_book_type_payout";      color = .blue
        case .reversal:    labelKey = "cash_book_type_reversal";    color = .orange
        }

        Text(labelKey)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func formatAmount(_ value: Double) -> String {
        let prefix = value >= 0 ? "+" : ""
        return prefix + (NumberFormatter.localizedString(from: value as NSNumber, number: .currency))
    }

    private func differenceText(diff: Double, counted: Double) -> String {
        let format = NSLocalizedString("cash_book_difference", comment: "")
        let diffStr = NumberFormatter.localizedString(from: diff as NSNumber, number: .currency)
        let countedStr = NumberFormatter.localizedString(from: counted as NSNumber, number: .currency)
        return String(format: format, diffStr, countedStr)
    }
}
```

- [ ] **Step 5.2: Regenerate + build**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
xcodegen generate
```

⌘B. Expected: succeeds.

- [ ] **Step 5.3: Commit**

```bash
git add ios/VMflow/Views/CashBook/EntriesListSection.swift \
        ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): add EntriesListSection component"
```

---

## Chunk 3: Action Sheets (Withdrawal + BankDeposit)

The two sheets that perform writes. Each owns its own form state and calls the VM mutation method.

### Task 6: WithdrawalSheet

**Files:**
- Create: `ios/VMflow/Views/CashBook/WithdrawalSheet.swift`

- [ ] **Step 6.1: Create the file**

```swift
import SwiftUI

struct WithdrawalSheet: View {
    let cashBook: CashBook
    /// Currently used only for analytics/future-proofing; description text is
    /// the same regardless of origin (matches web default exactly).
    let fromTour: Bool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var cashBookVM: CashBookViewModel

    @State private var counted: Decimal = 0
    @State private var description: String = NSLocalizedString("cash_book_default_withdrawal_desc", comment: "")
    @State private var selectedMachineId: UUID?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    /// Sheet-local copy of TheoreticalCash for the *passed-in* `cashBook`.
    /// Avoids relying on `cashBookVM.theoreticalCash` which may be stale
    /// or for a different Barkasse (multi-Barkasse refill case).
    @State private var theoretical: TheoreticalCash?

    private var difference: Decimal {
        let expected = Decimal(theoretical?.cashSalesSince ?? 0)
        return counted - expected
    }

    /// Machines scoped to *this sheet's* cashBook (not the VM's selected one).
    private var assignedMachines: [CashBookMachineRef] {
        cashBookVM.assignedMachines(for: cashBook.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent {
                        Text(theoretical?.cashSalesSince ?? 0, format: .currency(code: "EUR"))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    } label: {
                        Text("cash_book_expected_max")
                    }
                    if let machines = theoretical?.machines, !machines.isEmpty {
                        ForEach(machines) { m in
                            HStack {
                                Text(m.machineName ?? "—").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("+\(NumberFormatter.localizedString(from: m.cashSales as NSNumber, number: .currency))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("cash_book_changer_hint")
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                }

                Section("cash_book_counted_amount") {
                    TextField(value: $counted, format: .number) {
                        Text(verbatim: "0.00")
                    }
                    .keyboardType(.decimalPad)
                    .monospacedDigit()

                    if abs(difference) > Decimal(0.001) {
                        Text(differenceLabel)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("cash_book_description") {
                    TextField(text: $description) {
                        Text(verbatim: "")
                    }
                }

                if cashBook.trackPerMachine && !assignedMachines.isEmpty {
                    Section("cash_book_from_machine") {
                        Picker("cash_book_from_machine", selection: $selectedMachineId) {
                            Text("—").tag(UUID?.none)
                            ForEach(assignedMachines) { m in
                                Text(m.name ?? String(m.id.uuidString.prefix(8)))
                                    .tag(UUID?.some(m.id))
                            }
                        }
                        .labelsHidden()
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("cash_book_record_withdrawal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cash_book_cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("cash_book_book_entry")
                        }
                    }
                    .disabled(isSubmitting || counted <= 0)
                }
            }
            .task {
                // Always load fresh theoretical cash for the cash book this
                // sheet is for — even if the VM's selectedCashBookId points
                // elsewhere (multi-Barkasse refill case).
                await loadTheoretical()
            }
        }
    }

    private func loadTheoretical() async {
        // If the VM's selection already points at our cashBook, refresh via
        // the VM (so the rest of the app sees the same fresh value) and copy
        // the snapshot. Otherwise do a direct RPC to avoid mutating
        // vm.theoreticalCash to the wrong Barkasse.
        if cashBookVM.selectedCashBookId == cashBook.id {
            await cashBookVM.loadTheoreticalCash(for: cashBook.id)
            theoretical = cashBookVM.theoreticalCash
        } else {
            theoretical = await fetchTheoreticalDirect()
        }
    }

    /// Direct RPC call, used when this sheet is for a non-selected Barkasse.
    private func fetchTheoreticalDirect() async -> TheoreticalCash? {
        struct Params: Encodable {
            let p_cash_book_id: UUID
            let p_company_id: UUID
        }
        do {
            let result: TheoreticalCash = try await SupabaseService.shared.client
                .rpc("get_theoretical_cash",
                     params: Params(p_cash_book_id: cashBook.id, p_company_id: cashBook.companyId))
                .execute()
                .value
            return result
        } catch {
            return nil
        }
    }

    private var differenceLabel: String {
        let format = NSLocalizedString("cash_book_difference", comment: "")
        let diff = NumberFormatter.localizedString(from: NSDecimalNumber(decimal: abs(difference)), number: .currency)
        let counted = NumberFormatter.localizedString(from: NSDecimalNumber(decimal: self.counted), number: .currency)
        return String(format: format, diff, counted)
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let countedDouble = NSDecimalNumber(decimal: counted).doubleValue
            let expected = theoretical?.cashSalesSince ?? 0
            try await cashBookVM.recordWithdrawal(
                cashBookId: cashBook.id,
                counted: countedDouble,
                expected: expected,
                machineId: selectedMachineId,
                description: description
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 6.2: Regenerate + build**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
xcodegen generate
```

⌘B. Expected: succeeds.

- [ ] **Step 6.3: Commit**

```bash
git add ios/VMflow/Views/CashBook/WithdrawalSheet.swift \
        ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): add WithdrawalSheet for cash book"
```

### Task 7: BankDepositSheet

**Files:**
- Create: `ios/VMflow/Views/CashBook/BankDepositSheet.swift`

- [ ] **Step 7.1: Create the file**

```swift
import SwiftUI

struct BankDepositSheet: View {
    let cashBook: CashBook

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var cashBookVM: CashBookViewModel

    @State private var amount: Decimal = 0
    @State private var description: String = NSLocalizedString("cash_book_default_deposit_desc", comment: "")
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var currentBalance: Decimal {
        Decimal(cashBookVM.currentBalance)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent {
                        Text(cashBookVM.currentBalance, format: .currency(code: "EUR"))
                            .monospacedDigit()
                    } label: {
                        Text("cash_book_current_balance")
                    }
                }

                Section("cash_book_amount_to_bank") {
                    HStack {
                        TextField(value: $amount, format: .number) {
                            Text(verbatim: "0.00")
                        }
                        .keyboardType(.decimalPad)
                        .monospacedDigit()

                        Button("cash_book_full_amount") {
                            amount = currentBalance
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Section("cash_book_description") {
                    TextField(text: $description) {
                        Text(verbatim: "")
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("cash_book_record_payout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cash_book_cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("cash_book_book_deposit")
                        }
                    }
                    .disabled(isSubmitting || amount <= 0)
                }
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let amountDouble = NSDecimalNumber(decimal: amount).doubleValue
            try await cashBookVM.recordBankDeposit(
                cashBookId: cashBook.id,
                amount: amountDouble,
                description: description
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 7.2: Regenerate + build**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
xcodegen generate
```

⌘B. Expected: succeeds.

- [ ] **Step 7.3: Commit**

```bash
git add ios/VMflow/Views/CashBook/BankDepositSheet.swift \
        ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): add BankDepositSheet for cash book"
```

---

## Chunk 4: Main Screen + Sidebar Wiring

The full Cash Book screen + the navigation entry that gets there.

### Task 8: CashBookView (main screen)

**Files:**
- Create: `ios/VMflow/Views/CashBook/CashBookView.swift`

- [ ] **Step 8.1: Create the file**

```swift
import SwiftUI

struct CashBookView: View {
    @EnvironmentObject var cashBookVM: CashBookViewModel
    @State private var showWithdrawal = false
    @State private var showDeposit = false

    var body: some View {
        Group {
            if cashBookVM.cashBooks.isEmpty {
                emptyState
            } else if let book = cashBookVM.selectedCashBook {
                content(book: book)
            } else {
                pickerState
            }
        }
        .navigationTitle("cash_book_title")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await cashBookVM.refresh()
        }
        .task {
            // Refresh theoretical cash on every screen open
            if let id = cashBookVM.selectedCashBookId {
                await cashBookVM.loadTheoreticalCash(for: id)
            }
        }
    }

    @ViewBuilder
    private func content(book: CashBook) -> some View {
        List {
            Section {
                FlowVisualisationCard(
                    theoreticalCash: cashBookVM.theoreticalCash,
                    currentBalance: cashBookVM.currentBalance,
                    lastBankDeposit: cashBookVM.lastBankDeposit,
                    bankDepositThreshold: book.bankDepositThreshold,
                    onWithdraw: { showWithdrawal = true },
                    onDeposit: { showDeposit = true }
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }

            // Multi-Barkasse picker (only when multiple exist)
            if cashBookVM.cashBooks.count > 1 {
                Section {
                    Picker(selection: $cashBookVM.selectedCashBookId) {
                        ForEach(cashBookVM.cashBooks) { cb in
                            Text(cb.name).tag(UUID?.some(cb.id))
                        }
                    } label: {
                        Text(verbatim: book.name)
                    }
                }
            }

            Section("cash_book_title") {
                EntriesListSection(
                    entries: cashBookVM.entries,
                    machineName: { cashBookVM.machineName($0) }
                )
            }
        }
        .sheet(isPresented: $showWithdrawal) {
            WithdrawalSheet(cashBook: book, fromTour: false)
                .environmentObject(cashBookVM)
        }
        .sheet(isPresented: $showDeposit) {
            BankDepositSheet(cashBook: book)
                .environmentObject(cashBookVM)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "banknote")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("cash_book_no_barkasse_yet")
                .font(.headline)
            Text("cash_book_setup_in_web")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var pickerState: some View {
        // ≥2 Barkassen, no selection — let the user pick.
        VStack(spacing: 16) {
            Text("cash_book_title").font(.headline)
            ForEach(cashBookVM.cashBooks) { cb in
                Button(cb.name) {
                    cashBookVM.selectedCashBookId = cb.id
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}
```

- [ ] **Step 8.2: Regenerate + build**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
xcodegen generate
```

⌘B. Expected: succeeds.

- [ ] **Step 8.3: Commit**

```bash
git add ios/VMflow/Views/CashBook/CashBookView.swift \
        ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): add CashBookView main screen"
```

### Task 9: Sidebar / Tab navigation entry

**Files:**
- Modify: `ios/VMflow/Navigation/AppNavigation.swift`
- Modify: `ios/VMflow/Navigation/SidebarNavigationView.swift`
- Modify: `ios/VMflow/Navigation/CompactTabView.swift`

- [ ] **Step 9.1: Add `cashBook` to `SidebarItem`**

In `ios/VMflow/Navigation/AppNavigation.swift`, modify the enum:

```swift
enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case dashboard
    case machines
    case refill
    case inbox
    case cashBook                // ← NEW
    case products
    case warehouse
    case deals
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: "Dashboard"
        case .machines: "Machines"
        case .refill: "Refill"
        case .inbox: "Inbox"
        case .cashBook: NSLocalizedString("cash_book_title", comment: "")  // ← NEW
        case .products: "Products"
        case .warehouse: "Warehouse"
        case .deals: "Deals"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "chart.bar.fill"
        case .machines: "storefront.fill"
        case .refill: "arrow.clockwise.circle.fill"
        case .inbox: "tray.fill"
        case .cashBook: "banknote.fill"          // ← NEW
        case .products: "cube.box.fill"
        case .warehouse: "shippingbox.fill"
        case .deals: "tag.fill"
        case .settings: "gearshape.fill"
        }
    }

    var compactTab: AppTab? {
        switch self {
        case .dashboard: .dashboard
        case .machines: .machines
        case .refill: .refill
        case .inbox: .inbox
        default: nil  // products, warehouse, deals, settings, cashBook → More tab
        }
    }
}
```

- [ ] **Step 9.2: Wire `SidebarNavigationView` destination**

Open `ios/VMflow/Navigation/SidebarNavigationView.swift`. Find the `switch` that maps `SidebarItem` to a destination view (similar to how `case .warehouse` maps to `WarehouseView()`). Add the new case:

```swift
case .cashBook:
    CashBookView()
```

The exact placement depends on the existing structure — read the file first; if it has a `@ViewBuilder` `destinationView(for:)` helper, add the case there.

- [ ] **Step 9.3: Wire `CompactTabView` "More" entry**

Open `ios/VMflow/Navigation/CompactTabView.swift`. Find the "More" tab section that lists `products`, `warehouse`, `deals`, `settings` as `NavigationLink`s. Add an entry:

```swift
NavigationLink(value: SidebarItem.cashBook) {
    Label(SidebarItem.cashBook.label, systemImage: SidebarItem.cashBook.icon)
}
```

Place it in the same alphabetical/sensible position the spec uses (between `inbox` and `products`).

If the file uses a different routing pattern (e.g. `.navigationDestination(for: SidebarItem.self) { ... switch ... }`), add the `case .cashBook: CashBookView()` to the switch.

- [ ] **Step 9.4: Build + smoke**

⌘B then ⌘R. In the simulator:
- iPad layout: open the sidebar — "Kassenbuch" should appear as the 5th item with the banknote icon. Tap it → `CashBookView` loads. The flow card shows live values; the entries list renders.
- iPhone layout: tap "More" tab → see "Kassenbuch" entry → tap → same view.

Verify `refreshable` works: pull down to refresh. The list updates.

- [ ] **Step 9.5: Commit**

```bash
git add ios/VMflow/Navigation/AppNavigation.swift \
        ios/VMflow/Navigation/SidebarNavigationView.swift \
        ios/VMflow/Navigation/CompactTabView.swift
git commit -m "feat(ios): add Kassenbuch sidebar/tab navigation entry"
```

---

## Chunk 5: Dashboard tile

### Task 10: CashBookCard

**Files:**
- Create: `ios/VMflow/Views/Dashboard/CashBookCard.swift`
- Modify: `ios/VMflow/Views/Dashboard/DashboardView.swift`

- [ ] **Step 10.1: Create the card**

Create `ios/VMflow/Views/Dashboard/CashBookCard.swift`:

```swift
import SwiftUI

struct CashBookCard: View {
    @EnvironmentObject var cashBookVM: CashBookViewModel
    /// Set by the parent to push CashBookView when tapped.
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            content
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "banknote.fill").foregroundStyle(.green)
                Text("cash_book_title").font(.headline)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }

            if cashBookVM.cashBooks.isEmpty {
                Text("cash_book_setup_in_web")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let book = cashBookVM.selectedCashBook {
                FlowVisualisationCard(
                    theoreticalCash: cashBookVM.theoreticalCash,
                    currentBalance: cashBookVM.currentBalance,
                    lastBankDeposit: cashBookVM.lastBankDeposit,
                    bankDepositThreshold: book.bankDepositThreshold,
                    compact: true
                )
                if cashBookVM.currentBalance >= book.bankDepositThreshold {
                    Text("cash_book_deposit_recommended")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                // Multiple, none selected → just the title and "open" hint
                Text(verbatim: "→")
                    .font(.title2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
        .task {
            // Ensure theoretical cash is loaded for the dashboard tile too
            if let id = cashBookVM.selectedCashBookId {
                await cashBookVM.loadTheoreticalCash(for: id)
            }
        }
    }
}
```

- [ ] **Step 10.2: Insert into DashboardView**

Open `ios/VMflow/Views/Dashboard/DashboardView.swift`. Find the place where the top KPI cards (Today/Week sales) end and the Sales list begins. Insert `CashBookCard`:

```swift
// After the KPI HStack/VStack, before the sales list:
CashBookCard(onTap: {
    // Push CashBookView onto the same NavigationStack the dashboard uses.
    // The exact mechanism depends on existing navigation pattern —
    // typically a `@State private var showCashBook: Bool` with a
    // `.navigationDestination(isPresented:)`, or a NavigationLink.
    showCashBook = true
})
.padding(.horizontal)
```

Add at the top of `DashboardView`:
```swift
@State private var showCashBook = false
```

And the destination on the enclosing view:
```swift
.navigationDestination(isPresented: $showCashBook) {
    CashBookView()
}
```

> Read the existing `DashboardView` structure first — if it already uses `NavigationLink(value:)` with a typed destination, follow that pattern instead. Pick whichever matches the existing dashboard navigation pattern; do not introduce a new pattern.

- [ ] **Step 10.3: Regenerate project**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
xcodegen generate
```

`CashBookCard.swift` is now part of the Xcode target.

- [ ] **Step 10.4: Build + smoke**

⌘B then ⌘R. On the dashboard:
- The card appears between the existing KPI section and the sales list.
- The three station rows show live values.
- Tap the card → pushes onto `CashBookView`.
- Back arrow returns to dashboard with state preserved.

- [ ] **Step 10.5: Commit**

```bash
git add ios/VMflow/Views/Dashboard/CashBookCard.swift \
        ios/VMflow/Views/Dashboard/DashboardView.swift \
        ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): add CashBookCard dashboard tile"
```

---

## Chunk 6: Refill integration (auto-sheet + multi-Barkasse block)

The most distinctive UX piece — fires the WithdrawalSheet automatically when a tour ends and exactly one Barkasse with cash is involved.

### Task 11: Extend `RefillWizardViewModel` with refill-cashbook helpers

**Files:**
- Modify: `ios/VMflow/ViewModels/RefillWizardViewModel.swift`

- [ ] **Step 11.1: Add the two computed helpers**

The VM today already has a `tourLog: [TourLogEntry]` (you can confirm by grepping). Add at the bottom of the type:

```swift
// MARK: - Cash book integration

/// Result of resolving Barkassen-with-cash for this tour. Used by
/// `RefillSummaryView` to drive both the multi-Barkasse block and the
/// single-Barkasse auto-sheet.
struct TourCashResolution {
    let barkassen: [CashBook]                // those with cashSalesSince > 0
    let cashByCashBookId: [UUID: Double]     // map for O(1) lookup in the UI
}

extension RefillWizardViewModel {
    /// Set of machine IDs visited during this tour (non-skipped).
    var visitedMachineIds: Set<UUID> {
        Set(tourLog.filter { !$0.skipped }.map { $0.machineId })
    }

    /// Resolves which Barkassen need cash collection from this tour. Issues
    /// one RPC per candidate Barkasse (typically 0–2). Does NOT mutate the
    /// VM's `theoreticalCash` — uses `fetchTheoreticalCash(for:)` for an
    /// isolated read.
    func resolveTourCash(using cashBookVM: CashBookViewModel) async -> TourCashResolution {
        let candidates = cashBookVM.barkassenForVisitedMachines(visitedMachineIds)
        var withCash: [CashBook] = []
        var cashMap: [UUID: Double] = [:]
        for cb in candidates {
            if let tc = await cashBookVM.fetchTheoreticalCash(for: cb.id),
               tc.cashSalesSince > 0.001 {
                withCash.append(cb)
                cashMap[cb.id] = tc.cashSalesSince
            }
        }
        return TourCashResolution(barkassen: withCash, cashByCashBookId: cashMap)
    }
}
```

> **Note:** `resolveTourCash` is async because it needs to fetch theoretical cash for each candidate Barkasse via isolated RPC calls (one per candidate, typically 0–2). The result includes both the Barkasse list and a `cashByCashBookId` map for O(1) UI lookup. `RefillSummaryView` awaits this in its `.task` and stores the `TourCashResolution` in local state before deciding single-vs-multi.

- [ ] **Step 11.2: Build**

⌘B. Expected: succeeds.

- [ ] **Step 11.3: Commit**

```bash
git add ios/VMflow/ViewModels/RefillWizardViewModel.swift
git commit -m "feat(ios): add Barkasse-with-cash helpers to RefillWizardViewModel"
```

### Task 12: Create `MultiBarkasseCashBlock`

**Files:**
- Create: `ios/VMflow/Views/CashBook/MultiBarkasseCashBlock.swift`

- [ ] **Step 12.1: Create the file**

```swift
import SwiftUI

struct MultiBarkasseCashBlock: View {
    let barkassen: [CashBook]
    let expectedCashFor: (UUID) -> Double
    let onSelect: (CashBook) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "eurosign.circle.fill").foregroundStyle(.green)
                Text("cash_book_after_tour_hint").font(.subheadline.weight(.medium))
            }
            ForEach(barkassen) { cb in
                Button {
                    onSelect(cb)
                } label: {
                    HStack {
                        Text(cb.name).font(.subheadline)
                        Spacer()
                        Text(expectedCashFor(cb.id), format: .currency(code: "EUR"))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                if cb.id != barkassen.last?.id {
                    Divider()
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
        }
    }
}
```

- [ ] **Step 12.2: Regenerate project**

```bash
cd /Users/lucienkerl/Development/mdb-esp32-cashless/ios
xcodegen generate
```

- [ ] **Step 12.3: Build**

⌘B. Expected: succeeds.

- [ ] **Step 12.4: Commit**

```bash
git add ios/VMflow/Views/CashBook/MultiBarkasseCashBlock.swift \
        ios/VMflow.xcodeproj/project.pbxproj
git commit -m "feat(ios): add MultiBarkasseCashBlock for refill summary"
```

### Task 13: Wire the auto-sheet + multi block into `RefillSummaryView`

**Files:**
- Modify: `ios/VMflow/Views/Refill/RefillSummaryView.swift`

- [ ] **Step 13.1: Add cash-book state + auto-sheet**

Open the file. Modify the `View` to:

1. Inject `cashBookVM` via `@EnvironmentObject`.
2. Hold the post-resolution Barkasse list in `@State`.
3. Run the resolution `task` after the existing animation ticks.
4. Present the sheet for the single-Barkasse case via `.sheet(item:)`.
5. Render `MultiBarkasseCashBlock` for the multi case above the existing Done button.

Apply these changes to the existing view:

```swift
import SwiftUI

struct RefillSummaryView: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    @EnvironmentObject var cashBookVM: CashBookViewModel        // NEW
    @State private var showCheckmark = false
    @State private var showStats = false
    @State private var showButton = false
    @State private var tourCash: TourCashResolution?            // NEW
    @State private var autoSheetBarkasse: CashBook?             // NEW

    private var barkassenWithCash: [CashBook] { tourCash?.barkassen ?? [] }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // ... existing checkmark / title / stats cards (unchanged) ...

                // NEW: multi-Barkasse block (only when count >= 2)
                if barkassenWithCash.count >= 2 {
                    MultiBarkasseCashBlock(
                        barkassen: barkassenWithCash,
                        expectedCashFor: { id in tourCash?.cashByCashBookId[id] ?? 0 },
                        onSelect: { autoSheetBarkasse = $0 }
                    )
                    .padding(.horizontal)
                    .opacity(showButton ? 1 : 0)
                    .offset(y: showButton ? 0 : 16)
                    .animation(.easeOut(duration: 0.4), value: showButton)
                }

                // ... existing Done button (unchanged) ...
            }
        }
        .sheet(item: $autoSheetBarkasse) { barkasse in
            WithdrawalSheet(cashBook: barkasse, fromTour: true)
                .environmentObject(cashBookVM)
        }
        .task {
            // 1. Refresh the cash-book VM (fetch books + machines)
            await cashBookVM.refresh()
            // 2. Resolve which Barkassen need cash collection. Each candidate
            //    triggers one isolated RPC; total is typically 0–2 calls.
            let resolution = await viewModel.resolveTourCash(using: cashBookVM)
            tourCash = resolution

            // 3. If exactly one Barkasse needs cash, auto-present its sheet
            //    AFTER the existing Done-button reveal completes (~+1.7 s
            //    from view appearance). We wait the remaining time here
            //    instead of using a separate asyncAfter, so the trigger
            //    fires only after resolution is done — no race.
            if resolution.barkassen.count == 1 {
                let elapsedNs = UInt64(1.8 * 1_000_000_000)
                try? await Task.sleep(nanoseconds: elapsedNs)
                autoSheetBarkasse = resolution.barkassen.first
            }
        }
        .onAppear {
            // (existing +0.0 s and +0.4 s ticks unchanged — they live in the
            // current implementation; do not duplicate them.)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation { showButton = true }
            }
            // No auto-sheet asyncAfter here anymore — see `.task` above.
        }
    }
    // ... existing helper methods ...
}
```

> The exact splice points depend on the current file content. Read it first; the existing `body` has three sections — animation, stats, button — and you must:
> - Insert the multi block between stats and button
> - Add the new `.sheet` and `.task` modifiers on the outer `ScrollView`
> - Inject `@EnvironmentObject var cashBookVM`
> - Do NOT add an `asyncAfter(deadline: .now() + 1.8)` for the auto-sheet — that lived in an earlier draft of this plan but the race-free version uses `Task.sleep` inside `.task` instead.

> **Note on Task.sleep timing**: the sheet appearance is anchored to the time `.task` started, not the original view's `onAppear`. In practice these are within ~50ms of each other; the user perceives the sheet as appearing after the Done button finishes fading in. If the resolution takes longer than 1.8 s (slow network, many Barkassen), the sheet appears as soon as resolution finishes — preferable to never appearing.

- [ ] **Step 13.2: Build + smoke (single Barkasse)**

Setup: ensure the local DB has exactly **one** Barkasse with `track_per_machine` either on or off, and at least one machine assigned. Manually insert a `sales` row with `channel='cash'` for that machine so `cash_sales_since > 0`. (Use the web app's "Manueller Verkauf" form on `/machines/<id>` for the cleanest path.)

In Xcode: ⌘R. Run a refill tour through the iOS app:
1. Refill tab → start tour → visit at least the assigned machine → finish tour.
2. RefillSummaryView appears with checkmark + stats + Done button.
3. ~1.8 s later: `WithdrawalSheet` slides up.
4. Sheet shows the expected cash. Type the counted amount. Tap Buchen.
5. Sheet dismisses. Done button still visible. Tap Done.

Expected behaviour confirms single-Barkasse flow works.

- [ ] **Step 13.3: Smoke (multi Barkasse — optional)**

Setup: have **two** Barkassen, each with at least one machine, each with cash_sales > 0. Run a tour visiting machines from both.

Expected: no auto-sheet. The multi block appears with two rows. Tap either → that Barkasse's WithdrawalSheet opens; on dismiss, the summary stays.

- [ ] **Step 13.4: Smoke (no Barkasse / zero cash — regression)**

Setup: tour visiting machines that are NOT assigned to any Barkasse, or where cash_sales_since = 0.

Expected: summary view is identical to the pre-change behaviour. No block, no sheet.

- [ ] **Step 13.5: Commit**

```bash
git add ios/VMflow/Views/Refill/RefillSummaryView.swift
git commit -m "feat(ios): integrate Kassenbuch auto-sheet and multi-Barkasse block into refill summary"
```

---

## Chunk 7: Final smoke walk + version bump

### Task 14: End-to-end walkthrough

- [ ] **Step 14.1: Cold-launch verification**

Force-quit the simulator app. Reopen. Log in.
- Dashboard shows the new cash book card with values.
- Sidebar/More shows "Kassenbuch" as the 5th-ish entry.
- Tap card → push `CashBookView`. Back arrow returns. Tile values consistent.

- [ ] **Step 14.2: Persisted selection**

If multiple Barkassen exist in the DB:
- On `CashBookView`, tap the picker, change selection.
- Force-quit app. Reopen.
- The previously selected Barkasse is still active.

- [ ] **Step 14.3: Bank deposit**

From the main `CashBookView`:
- Tap "Geld auf Bank einzahlen" CTA.
- BankDepositSheet opens with current balance shown.
- Tap "Gesamten Bestand" → amount field fills.
- Tap "Einzahlung buchen".
- Sheet dismisses; entries list shows new "Bankeinzahlung" row at top; current balance drops.
- Dashboard tile (after navigating back) reflects the change.

- [ ] **Step 14.4: Withdrawal from main screen (no tour)**

- Tap "Geld aus Automat entnehmen" CTA on `CashBookView`.
- WithdrawalSheet opens.
- Type counted amount, tap Buchen.
- New entry appears at the top of the entries list.
- "In Automaten" station drops to 0 (or to the residual after refresh).

- [ ] **Step 14.5: Localization**

In iOS Settings, change the language between Deutsch and English. Reopen the app. Confirm:
- Sidebar label "Kassenbuch" / "Cash Book"
- Station labels "In Automaten" / "In machines", "In der Kasse" / "In cash box", "Letzte Bankeinzahlung" / "Last bank deposit"
- Both sheets, both buttons.

- [ ] **Step 14.6: Bump app version (if conventional)**

Open `Configurations/Debug.xcconfig` or the project's version-bump location and increment the build number. Commit:

```bash
git add ios/Configurations/
git commit -m "chore(ios): bump build for Kassenbuch feature"
```

(Skip if your team handles version bumps elsewhere.)

- [ ] **Step 14.7: Final commit (if any leftovers)**

```bash
git status
# If clean, the feature is done.
```

---

## Wrap-up

- [ ] **Step W.1: Confirm file count and sizes**

```bash
wc -l \
  ios/VMflow/Models/CashBook.swift \
  ios/VMflow/ViewModels/CashBookViewModel.swift \
  ios/VMflow/Views/CashBook/*.swift \
  ios/VMflow/Views/Dashboard/CashBookCard.swift
```

Expected total: ~1,200 lines across 9 new files. No file should exceed ~400 lines.

- [ ] **Step W.2: Run a final build with all warnings visible**

In Xcode, Product → Build (⌘B). Confirm zero warnings introduced by this work. (Existing warnings unrelated to cash-book code are out of scope.)

- [ ] **Step W.3: PR / review**

If the team uses pull requests, open one referencing the spec at [docs/superpowers/specs/2026-05-08-ios-cashbook-design.md](../specs/2026-05-08-ios-cashbook-design.md). Otherwise the work is on `main`.

---

## Skills Reference

- @superpowers:subagent-driven-development — preferred execution mode
- @superpowers:executing-plans — fallback execution mode
- @superpowers:verification-before-completion — before marking the plan done

## Out-of-Scope (do NOT add in this plan)

- Correction / Storno sheets
- Settings / Create / Delete Barkasse modals
- Machine-assignment UI
- PDF export
- Real-time updates via Supabase channels
- Push notifications when threshold is crossed
- Background sync
- Hash-chain verification UI

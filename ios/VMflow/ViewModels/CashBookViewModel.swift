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

    /// Switch the active Barkasse and reload its entries + theoretical cash.
    /// Clears stale state before fetching so the UI doesn't briefly show the
    /// previous Barkasse's data in transit.
    func selectCashBook(_ id: UUID) async {
        guard id != selectedCashBookId else { return }
        // Clear stale state up-front
        entries = []
        theoreticalCash = nil
        selectedCashBookId = id
        await loadEntries(for: id)
        await loadTheoreticalCash(for: id)
    }

    /// Resolve a machine ID to a name for display.
    func machineName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return machines.first(where: { $0.id == id })?.name
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

            let (books, fetchedMachines) = try await (booksTask, machinesTask)
            self.cashBooks = books
            self.machines = fetchedMachines
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

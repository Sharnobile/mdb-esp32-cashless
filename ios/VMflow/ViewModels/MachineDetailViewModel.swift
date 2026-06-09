import Foundation
import Supabase

/// Drives the machine detail view: overview, sales history, and tray data.
@MainActor
final class MachineDetailViewModel: ObservableObject {
    @Published var machine: VendingMachine
    @Published var stats: MachineStats
    @Published var trays: [Tray] = []
    @Published var recentSales: [Sale] = []
    @Published var products: [Product] = []
    @Published var suppressedSales: [SuppressedSale] = []
    @Published var isLoading = false
    @Published var error: String?

    private let client = SupabaseService.shared.client

    init(machine: VendingMachine, stats: MachineStats) {
        self.machine = machine
        self.stats = stats
    }

    // MARK: - Load Detail

    func loadDetail() async {
        isLoading = true
        error = nil

        do {
            async let traysTask: () = loadTrays()
            async let salesTask: () = loadSales()
            async let productsTask: () = loadProducts()

            _ = try await (traysTask, salesTask, productsTask)
        } catch is CancellationError {
            // Ignore — SwiftUI cancels refreshable tasks routinely
        } catch {
            self.error = error.localizedDescription
        }

        // Best-effort supplemental load — never blocks or fails the main detail load.
        try? await loadSuppressedSales()

        isLoading = false
    }

    // MARK: - Trays

    private func loadTrays() async throws {
        trays = try await client
            .from("machine_trays")
            .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued, sellprice)")
            .eq("machine_id", value: machine.id.uuidString)
            .order("item_number", ascending: true)
            .execute()
            .value
    }

    // MARK: - Sales

    private func loadSales() async throws {
        recentSales = try await client
            .from("sales")
            .select("id, created_at, item_price, item_number, machine_id, embedded_id, channel, product_id, products(name, image_path)")
            .eq("machine_id", value: machine.id.uuidString)
            .order("created_at", ascending: false)
            .limit(50)
            .execute()
            .value
    }

    // MARK: - Products (for tray editing)

    private func loadProducts() async throws {
        products = try await client
            .from("products")
            .select("id, name, image_path, discontinued, sellprice")
            .eq("discontinued", value: false)
            .order("name", ascending: true)
            .execute()
            .value
    }

    // MARK: - Suppressed sales (auto-removed brownout duplicates)

    private func loadSuppressedSales() async throws {
        guard let embeddedId = machine.embedded?.uuidString else {
            suppressedSales = []   // no embedded device → no suppressed sales possible
            return
        }
        suppressedSales = try await client
            .from("suppressed_sales")
            .select("id, embedded_id, item_number, item_price, channel, sale_seq, device_created_at, received_at, matched_sale_id, reason, product_id, products(name, image_path), matched:sales!matched_sale_id(created_at)")
            .eq("embedded_id", value: embeddedId)
            .order("received_at", ascending: false)
            .limit(100)
            .execute()
            .value
    }

    // MARK: - Restore suppressed sale

    /// Promote an auto-removed (suppressed) sale back into a real sale via the
    /// restore_suppressed_sale RPC, then reload so it leaves Duplicates and
    /// appears under Sales (stock −1). Admin-only; the RPC enforces it too.
    func restoreSuppressed(_ id: UUID) async {
        struct Params: Encodable { let p_suppressed_id: UUID }
        do {
            try await client
                .rpc("restore_suppressed_sale", params: Params(p_suppressed_id: id))
                .execute()
            await loadDetail()   // refreshes trays, sales, AND suppressedSales
        } catch is CancellationError {
            // Ignore — SwiftUI cancels routinely
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Stock Actions

    /// Adjust stock for a tray by a delta amount.
    func adjustStock(tray: Tray, delta: Int) async {
        let newStock = max(0, min(tray.capacity, tray.currentStock + delta))
        guard newStock != tray.currentStock else { return }

        do {
            try await client
                .from("machine_trays")
                .update(["current_stock": newStock])
                .eq("id", value: tray.id.uuidString)
                .execute()

            // Reload trays
            try await loadTrays()
        } catch is CancellationError {
            // Ignore — SwiftUI cancels refreshable tasks routinely
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Fill a tray to its capacity.
    func fillTray(_ tray: Tray) async {
        do {
            try await client
                .from("machine_trays")
                .update(["current_stock": tray.capacity])
                .eq("id", value: tray.id.uuidString)
                .execute()

            try await loadTrays()
        } catch is CancellationError {
            // Ignore — SwiftUI cancels refreshable tasks routinely
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Revenue Helpers

    /// Today's revenue for this machine.
    var todayRevenue: Double {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return recentSales
            .filter { $0.createdAt >= startOfToday }
            .reduce(0) { $0 + ($1.itemPrice ?? 0) }
    }

    /// Formatted stock health summary.
    var stockSummary: String {
        let empty = trays.filter { $0.isEmpty }.count
        let low = trays.filter { $0.isBelowMinStock && !$0.isEmpty }.count

        if empty > 0 { return "\(empty) empty, \(low) low" }
        if low > 0 { return "\(low) low" }
        return "All good"
    }
}

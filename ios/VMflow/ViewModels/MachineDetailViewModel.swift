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
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Trays

    private func loadTrays() async throws {
        trays = try await client
            .from("machine_trays")
            .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued)")
            .eq("machine_id", value: machine.id.uuidString)
            .order("item_number", ascending: true)
            .execute()
            .value
    }

    // MARK: - Sales

    private func loadSales() async throws {
        recentSales = try await client
            .from("sales")
            .select("id, created_at, item_price, item_number, machine_id, embedded_id, channel")
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

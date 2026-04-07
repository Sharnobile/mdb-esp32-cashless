import Foundation
import Supabase

/// CRUD operations for machine trays: fetch, add, batch add, edit, delete, stock adjust.
@MainActor
final class TrayViewModel: ObservableObject {
    @Published var trays: [Tray] = []
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var error: String?

    let machineId: UUID
    private let client = SupabaseService.shared.client

    init(machineId: UUID) {
        self.machineId = machineId
    }

    // MARK: - Fetch

    func loadTrays() async {
        isLoading = true
        error = nil

        do {
            trays = try await client
                .from("machine_trays")
                .select("id, machine_id, item_number, product_id, capacity, current_stock, min_stock, fill_when_below, products(name, image_path, discontinued)")
                .eq("machine_id", value: machineId.uuidString)
                .order("item_number", ascending: true)
                .execute()
                .value
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Add Single Tray

    func addTray(itemNumber: Int, productId: UUID?, capacity: Int, currentStock: Int, minStock: Int, fillWhenBelow: Int) async {
        isSaving = true
        error = nil

        let payload = TrayUpsert(
            machineId: machineId,
            itemNumber: itemNumber,
            productId: productId,
            capacity: capacity,
            currentStock: currentStock,
            minStock: minStock,
            fillWhenBelow: fillWhenBelow
        )

        do {
            try await client
                .from("machine_trays")
                .insert(payload)
                .execute()

            await loadTrays()
        } catch {
            self.error = error.localizedDescription
        }

        isSaving = false
    }

    // MARK: - Batch Add

    /// Creates sequential trays starting from `startSlot` with the given count and capacity.
    func batchAddTrays(startSlot: Int, count: Int, capacity: Int) async {
        isSaving = true
        error = nil

        var payloads: [TrayUpsert] = []
        for i in 0..<count {
            payloads.append(TrayUpsert(
                machineId: machineId,
                itemNumber: startSlot + i,
                productId: nil,
                capacity: capacity,
                currentStock: 0,
                minStock: 0,
                fillWhenBelow: 0
            ))
        }

        do {
            try await client
                .from("machine_trays")
                .insert(payloads)
                .execute()

            await loadTrays()
        } catch {
            self.error = error.localizedDescription
        }

        isSaving = false
    }

    // MARK: - Update Tray

    func updateTray(id: UUID, itemNumber: Int, productId: UUID?, capacity: Int, currentStock: Int, minStock: Int, fillWhenBelow: Int) async {
        isSaving = true
        error = nil

        let payload = TrayUpsert(
            machineId: machineId,
            itemNumber: itemNumber,
            productId: productId,
            capacity: capacity,
            currentStock: currentStock,
            minStock: minStock,
            fillWhenBelow: fillWhenBelow
        )

        do {
            try await client
                .from("machine_trays")
                .update(payload)
                .eq("id", value: id.uuidString)
                .execute()

            await loadTrays()
        } catch {
            self.error = error.localizedDescription
        }

        isSaving = false
    }

    // MARK: - Delete

    func deleteTray(_ tray: Tray) async {
        do {
            try await client
                .from("machine_trays")
                .delete()
                .eq("id", value: tray.id.uuidString)
                .execute()

            trays.removeAll { $0.id == tray.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Stock Adjustments

    func adjustStock(tray: Tray, delta: Int) async {
        let newStock = max(0, min(tray.capacity, tray.currentStock + delta))
        guard newStock != tray.currentStock else { return }

        do {
            try await client
                .from("machine_trays")
                .update(["current_stock": newStock])
                .eq("id", value: tray.id.uuidString)
                .execute()

            await loadTrays()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func fillToCapacity(_ tray: Tray) async {
        guard tray.currentStock < tray.capacity else { return }

        do {
            try await client
                .from("machine_trays")
                .update(["current_stock": tray.capacity])
                .eq("id", value: tray.id.uuidString)
                .execute()

            await loadTrays()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Fill all trays to capacity.
    func fillAll() async {
        isSaving = true
        for tray in trays where tray.currentStock < tray.capacity {
            do {
                try await client
                    .from("machine_trays")
                    .update(["current_stock": tray.capacity])
                    .eq("id", value: tray.id.uuidString)
                    .execute()
            } catch {
                self.error = error.localizedDescription
            }
        }
        await loadTrays()
        isSaving = false
    }
}

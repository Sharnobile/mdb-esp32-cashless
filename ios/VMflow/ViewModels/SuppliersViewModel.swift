import Foundation
import Supabase

/// Manages the company's supplier list: load, rename, delete. Suppliers are
/// otherwise created implicitly by `add_purchase_price`/`update_purchase_price`
/// (see PurchasePricesViewModel) when a new name is typed in the price editor —
/// this screen is where they get tidied up afterwards.
@MainActor
final class SuppliersViewModel: ObservableObject {
    @Published var suppliers: [Supplier] = []
    @Published var isLoading = false
    @Published var error: String?

    private let client = SupabaseService.shared.client

    func loadSuppliers() async {
        isLoading = true; defer { isLoading = false }
        do {
            suppliers = try await client.from("suppliers")
                .select("id, name, email, phone, address, customer_number")
                .order("name", ascending: true).execute().value
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    /// Persists all editable fields of a supplier (name + contact info).
    @discardableResult
    func updateSupplier(_ supplier: Supplier) async -> Bool {
        let trimmedName = supplier.name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return false }
        struct Update: Encodable {
            let name: String
            let email: String?
            let phone: String?
            let address: String?
            let customerNumber: String?
            enum CodingKeys: String, CodingKey {
                case name, email, phone, address
                case customerNumber = "customer_number"
            }
        }
        let blank = { (s: String?) in (s?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } }
        do {
            try await client.from("suppliers")
                .update(Update(name: trimmedName, email: blank(supplier.email), phone: blank(supplier.phone),
                                address: blank(supplier.address), customerNumber: blank(supplier.customerNumber)))
                .eq("id", value: supplier.id.uuidString).execute()
            if let idx = suppliers.firstIndex(where: { $0.id == supplier.id }) {
                suppliers[idx] = Supplier(id: supplier.id, name: trimmedName, email: blank(supplier.email),
                                           phone: blank(supplier.phone), address: blank(supplier.address),
                                           customerNumber: blank(supplier.customerNumber))
                suppliers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            return true
        } catch {
            let desc = String(describing: error)
            if desc.localizedCaseInsensitiveContains("duplicate") || desc.contains("23505") {
                self.error = String(localized: "A supplier with this name already exists.")
            } else {
                self.error = error.localizedDescription
            }
            return false
        }
    }

    @discardableResult
    func deleteSupplier(id: UUID) async -> Bool {
        do {
            try await client.from("suppliers").delete().eq("id", value: id.uuidString).execute()
            suppliers.removeAll { $0.id == id }
            return true
        } catch {
            let desc = String(describing: error)
            if desc.localizedCaseInsensitiveContains("foreign key") || desc.contains("23503") {
                self.error = String(localized: "This supplier is still used by a purchase price and can't be deleted.")
            } else {
                self.error = error.localizedDescription
            }
            return false
        }
    }
}

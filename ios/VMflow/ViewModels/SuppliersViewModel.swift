import Foundation
import Supabase

/// Manages the company's supplier list: load, create, rename, delete.
/// Suppliers can also appear implicitly via `add_purchase_price`/
/// `update_purchase_price` (see PurchasePricesViewModel) when a new name is
/// typed in the price editor.
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

    /// Creates a supplier for the current company. `company_id` is required by
    /// the `suppliers_insert` RLS policy, so it is resolved from
    /// `organization_members` first.
    @discardableResult
    func createSupplier(name: String, email: String?, phone: String?,
                        address: String?, customerNumber: String?) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return false }
        struct Insert: Encodable {
            let companyId: UUID
            let name: String
            let email: String?
            let phone: String?
            let address: String?
            let customerNumber: String?
            enum CodingKeys: String, CodingKey {
                case name, email, phone, address
                case companyId = "company_id"
                case customerNumber = "customer_number"
            }
        }
        do {
            let companyId = try await fetchCompanyId()
            let created: [Supplier] = try await client.from("suppliers")
                .insert(Insert(companyId: companyId, name: trimmedName, email: blank(email),
                                phone: blank(phone), address: blank(address),
                                customerNumber: blank(customerNumber)))
                .select("id, name, email, phone, address, customer_number")
                .execute().value
            if let supplier = created.first {
                suppliers.append(supplier)
                suppliers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            } else {
                await loadSuppliers()
            }
            return true
        } catch {
            report(error)
            return false
        }
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
            report(error)
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

    // MARK: - Helpers

    /// Trims a free-text field and collapses empty strings to nil so blank
    /// contact fields are stored as NULL rather than "".
    private func blank(_ s: String?) -> String? {
        (s?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Maps the unique-name constraint to a readable message; everything else
    /// falls through to the underlying description.
    private func report(_ error: Error) {
        let desc = String(describing: error)
        if desc.localizedCaseInsensitiveContains("duplicate") || desc.contains("23505") {
            self.error = String(localized: "A supplier with this name already exists.")
        } else {
            self.error = error.localizedDescription
        }
    }

    /// Fetches the current user's company_id from organization_members.
    private func fetchCompanyId() async throws -> UUID {
        let userId = try await client.auth.session.user.id

        struct OrgMember: Decodable {
            let companyId: UUID
            enum CodingKeys: String, CodingKey { case companyId = "company_id" }
        }

        let members: [OrgMember] = try await client
            .from("organization_members")
            .select("company_id")
            .eq("user_id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value

        guard let companyId = members.first?.companyId else {
            throw NSError(domain: "SuppliersVM", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not determine company")])
        }
        return companyId
    }
}

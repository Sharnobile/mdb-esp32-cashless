import Foundation
import Supabase

@MainActor
final class PurchasePricesViewModel: ObservableObject {
    @Published var suppliers: [Supplier] = []
    @Published var prices: [PurchasePrice] = []
    @Published var resolvedRate: Double? = nil
    @Published var isLoading = false
    @Published var error: String?

    private let client = SupabaseService.shared.client

    func loadSuppliers() async {
        do {
            suppliers = try await client.from("suppliers")
                .select("id, name").order("name", ascending: true).execute().value
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    func loadPrices(productId: UUID) async {
        isLoading = true; defer { isLoading = false }
        do {
            prices = try await client.from("product_purchase_prices")
                .select("id, product_id, supplier_id, price_net, price_gross, price_basis, tax_rate, observed_on, note, suppliers(name)")
                .eq("product_id", value: productId.uuidString)
                .order("observed_on", ascending: false)
                .order("created_at", ascending: false)
                .execute().value
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    /// Resolves the product's effective tax rate (nil → caller must supply an override %).
    func resolveTaxRate(productId: UUID) async {
        do {
            resolvedRate = try await client
                .rpc("resolve_product_tax_rate", params: ["p_product_id": AnyJSON.string(productId.uuidString)])
                .execute().value
        } catch { resolvedRate = nil }
    }

    @discardableResult
    func addPrice(productId: UUID, supplierName: String, price: Double, basis: String,
                  observedOn: String, note: String?, taxRateOverride: Double?) async -> Bool {
        do {
            let params: [String: AnyJSON] = [
                "p_product_id": .string(productId.uuidString),
                "p_supplier_name": .string(supplierName),
                "p_price": .double(price),
                "p_basis": .string(basis),
                "p_observed_on": .string(observedOn),
                "p_note": note.map { AnyJSON.string($0) } ?? .null,
                "p_tax_rate_override": taxRateOverride.map { AnyJSON.double($0) } ?? .null,
            ]
            try await client.rpc("add_purchase_price", params: params).execute()
            await loadSuppliers(); await loadPrices(productId: productId)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func updatePrice(id: UUID, productId: UUID, supplierName: String, price: Double, basis: String,
                     observedOn: String, note: String?, taxRateOverride: Double?) async -> Bool {
        do {
            let params: [String: AnyJSON] = [
                "p_id": .string(id.uuidString),
                "p_supplier_name": .string(supplierName),
                "p_price": .double(price),
                "p_basis": .string(basis),
                "p_observed_on": .string(observedOn),
                "p_note": note.map { AnyJSON.string($0) } ?? .null,
                "p_tax_rate_override": taxRateOverride.map { AnyJSON.double($0) } ?? .null,
            ]
            try await client.rpc("update_purchase_price", params: params).execute()
            await loadSuppliers(); await loadPrices(productId: productId)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func deletePrice(id: UUID, productId: UUID) async {
        do {
            try await client.from("product_purchase_prices").delete().eq("id", value: id.uuidString).execute()
            await loadPrices(productId: productId)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    /// Batch summaries for the deals screen / product list.
    func fetchSummaries(productIds: [UUID]) async -> [UUID: ProductPurchaseSummary] {
        guard !productIds.isEmpty else { return [:] }
        do {
            // Bind to an explicit [String: AnyJSON] so the `.array` case resolves —
            // rpc(params:) is generic (`some Encodable`), and an inline literal
            // can't infer the dictionary value type from `.array(...)` alone.
            let params: [String: AnyJSON] = [
                "p_product_ids": .array(productIds.map { AnyJSON.string($0.uuidString) })
            ]
            let rows: [ProductPurchaseSummary] = try await client
                .rpc("get_product_purchase_summary", params: params)
                .execute().value
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.productId, $0) })
        } catch { return [:] }
    }
}

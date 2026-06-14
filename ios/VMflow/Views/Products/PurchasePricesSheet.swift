import SwiftUI

/// Manage a product's purchase prices: history (★ cheapest, "usual" = newest),
/// add/edit with net/gross toggle + live counterpart, fallback tax %, and margin.
struct PurchasePricesSheet: View {
    let productId: UUID
    let sellprice: Double?

    @StateObject private var vm = PurchasePricesViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var supplierName = ""
    @State private var priceText = ""
    @State private var basis: PriceBasis = .net
    @State private var observedOn = Date()
    @State private var note = ""
    @State private var taxRatePctText = ""
    @State private var editingId: UUID? = nil
    @State private var formError: String?

    private var needRateOverride: Bool { vm.resolvedRate == nil }
    private var effectiveRate: Double? {
        needRateOverride ? Double(taxRatePctText).map { $0 / 100 } : vm.resolvedRate
    }
    private var priceValue: Double? { Double(priceText.replacingOccurrences(of: ",", with: ".")) }
    private var counterpartText: String? {
        guard let p = priceValue, let r = effectiveRate else { return nil }
        let other = PurchaseComparison.counterpart(p, basis: basis, rate: r)
        let label = basis == .net ? String(localized: "gross") : String(localized: "net")
        return String(format: "= %.2f \u{20AC} %@", other, label)
    }
    private var newest: PurchasePrice? { vm.prices.first }
    private var cheapestId: UUID? { vm.prices.min(by: { $0.priceGross < $1.priceGross })?.id }
    private var margin: (rohertrag: Double, spannePct: Double)? {
        guard let n = newest else { return nil }
        return PurchaseComparison.marginNet(sellpriceGross: sellprice, ekNet: n.priceNet, rate: n.taxRate)
    }

    private static let isoDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Recorded prices")) {
                    if vm.prices.isEmpty {
                        Text(String(localized: "No purchase prices recorded yet."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(vm.prices) { p in
                        HStack {
                            if p.id == cheapestId { Text("★") }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.supplierName).font(.subheadline)
                                Text(String(format: "%.2f \u{20AC} %@ · %.2f \u{20AC} %@ · %@",
                                            p.priceNet, String(localized: "net"),
                                            p.priceGross, String(localized: "gross"), p.observedOn))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if p.id == newest?.id {
                                Text(String(localized: "usual")).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { startEdit(p) }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await vm.deletePrice(id: p.id, productId: productId) }
                            } label: { Text(String(localized: "Delete")) }
                        }
                    }
                }

                Section(editingId == nil ? String(localized: "Add purchase price") : String(localized: "Edit purchase price")) {
                    TextField(String(localized: "Supplier"), text: $supplierName)
                    if !vm.suppliers.isEmpty {
                        Menu(String(localized: "Pick existing supplier")) {
                            ForEach(vm.suppliers) { s in Button(s.name) { supplierName = s.name } }
                        }.font(.caption)
                    }
                    TextField(String(localized: "Price per unit"), text: $priceText)
                        .keyboardType(.decimalPad)
                    Picker(String(localized: "Basis"), selection: $basis) {
                        Text(String(localized: "net")).tag(PriceBasis.net)
                        Text(String(localized: "gross")).tag(PriceBasis.gross)
                    }.pickerStyle(.segmented)
                    if let c = counterpartText { Text(c).font(.caption).foregroundStyle(.secondary) }
                    if needRateOverride {
                        TextField(String(localized: "Tax rate % (no rate on product)"), text: $taxRatePctText)
                            .keyboardType(.decimalPad)
                    }
                    DatePicker(String(localized: "Date"), selection: $observedOn, displayedComponents: .date)
                    TextField(String(localized: "Note"), text: $note)
                    if let e = formError { Text(e).font(.caption).foregroundStyle(.red) }
                    Button(editingId == nil ? String(localized: "Add") : String(localized: "Save")) {
                        Task { await submit() }
                    }
                    if editingId != nil {
                        Button(String(localized: "Cancel"), role: .cancel) { resetForm() }
                    }
                }

                if let m = margin {
                    Section(String(localized: "Margin")) {
                        Text(String(format: "%.2f \u{20AC} · %.0f%%", m.rohertrag, m.spannePct))
                        Text(String(localized: "net sell price − usual net purchase price"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(String(localized: "Purchase prices"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .task {
                await vm.loadSuppliers()
                await vm.loadPrices(productId: productId)
                await vm.resolveTaxRate(productId: productId)
            }
        }
    }

    private func startEdit(_ p: PurchasePrice) {
        editingId = p.id
        supplierName = p.supplierName
        basis = PriceBasis(rawValue: p.priceBasis) ?? .net
        priceText = String(format: "%.4f", p.priceBasis == "net" ? p.priceNet : p.priceGross)
        observedOn = Self.isoDate.date(from: p.observedOn) ?? Date()
        note = p.note ?? ""
        taxRatePctText = needRateOverride ? String(format: "%.2f", p.taxRate * 100) : ""
    }

    private func resetForm() {
        editingId = nil; supplierName = ""; priceText = ""; basis = .net
        observedOn = Date(); note = ""; taxRatePctText = ""; formError = nil
    }

    private func submit() async {
        guard !supplierName.trimmingCharacters(in: .whitespaces).isEmpty, let price = priceValue else {
            formError = String(localized: "Supplier and price are required."); return
        }
        if needRateOverride && Double(taxRatePctText) == nil {
            formError = String(localized: "Please provide a tax rate."); return
        }
        formError = nil
        let dateStr = Self.isoDate.string(from: observedOn)
        let override = needRateOverride ? Double(taxRatePctText).map { $0 / 100 } : nil
        let name = supplierName.trimmingCharacters(in: .whitespaces)
        let ok: Bool
        if let id = editingId {
            ok = await vm.updatePrice(id: id, productId: productId, supplierName: name, price: price,
                                      basis: basis.rawValue, observedOn: dateStr, note: note.isEmpty ? nil : note,
                                      taxRateOverride: override)
        } else {
            ok = await vm.addPrice(productId: productId, supplierName: name, price: price,
                                   basis: basis.rawValue, observedOn: dateStr, note: note.isEmpty ? nil : note,
                                   taxRateOverride: override)
        }
        if ok { resetForm() } else { formError = vm.error }
    }
}

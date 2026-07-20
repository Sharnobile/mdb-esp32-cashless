import SwiftUI

/// Company-wide supplier management, reachable from the "More" tab: list, rename,
/// delete. Suppliers themselves are created implicitly from the purchase-price
/// editor (see PurchasePricesSheet.SupplierPickerView) — this screen is for
/// cleaning them up afterwards (typo fixes, removing unused entries).
struct SuppliersView: View {
    @StateObject private var vm = SuppliersViewModel()
    @State private var renamingSupplier: Supplier?
    @State private var renameText = ""

    var body: some View {
        List {
            if vm.suppliers.isEmpty && !vm.isLoading {
                Text(String(localized: "No suppliers yet.")).foregroundStyle(.secondary)
            }
            ForEach(vm.suppliers) { supplier in
                Button {
                    renamingSupplier = supplier
                    renameText = supplier.name
                } label: {
                    Text(supplier.name).foregroundStyle(.primary)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        Task { await vm.deleteSupplier(id: supplier.id) }
                    } label: {
                        Label(String(localized: "Delete"), systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Suppliers"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadSuppliers() }
        .refreshable { await vm.loadSuppliers() }
        .alert(
            String(localized: "Rename Supplier"),
            isPresented: Binding(
                get: { renamingSupplier != nil },
                set: { if !$0 { renamingSupplier = nil } }
            )
        ) {
            TextField(String(localized: "Supplier"), text: $renameText)
                .autocorrectionDisabled()
            Button(String(localized: "Cancel"), role: .cancel) { renamingSupplier = nil }
            Button(String(localized: "Save")) {
                if let s = renamingSupplier {
                    Task { await vm.renameSupplier(id: s.id, name: renameText) }
                }
                renamingSupplier = nil
            }
        }
        .alert(
            String(localized: "Error"),
            isPresented: Binding(get: { vm.error != nil }, set: { if !$0 { vm.error = nil } })
        ) {
            Button(String(localized: "OK")) { vm.error = nil }
        } message: {
            Text(vm.error ?? "")
        }
    }
}

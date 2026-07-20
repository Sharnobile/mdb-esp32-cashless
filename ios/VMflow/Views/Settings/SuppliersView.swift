import SwiftUI

/// Company-wide supplier management, reachable from the "More" tab: list, edit
/// (name + contact info), delete. Suppliers themselves are created implicitly
/// from the purchase-price editor (see PurchasePricesSheet.SupplierPickerView)
/// or the warehouse intake supplier picker — this screen is for filling in
/// their details and cleaning them up afterwards (typo fixes, removing unused
/// entries).
struct SuppliersView: View {
    @StateObject private var vm = SuppliersViewModel()
    @State private var editingSupplier: Supplier?

    var body: some View {
        List {
            if vm.suppliers.isEmpty && !vm.isLoading {
                Text(String(localized: "No suppliers yet.")).foregroundStyle(.secondary)
            }
            ForEach(vm.suppliers) { supplier in
                Button {
                    editingSupplier = supplier
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(supplier.name).foregroundStyle(.primary)
                        if let email = supplier.email, !email.isEmpty {
                            Text(email).font(.caption).foregroundStyle(.secondary)
                        } else if let phone = supplier.phone, !phone.isEmpty {
                            Text(phone).font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
        .sheet(item: $editingSupplier) { supplier in
            SupplierEditSheet(supplier: supplier) { updated in
                await vm.updateSupplier(updated)
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

/// Edit a supplier's name and contact/reference info.
private struct SupplierEditSheet: View {
    let supplier: Supplier
    let onSave: (Supplier) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var email: String
    @State private var phone: String
    @State private var address: String
    @State private var customerNumber: String
    @State private var isSaving = false

    init(supplier: Supplier, onSave: @escaping (Supplier) async -> Void) {
        self.supplier = supplier
        self.onSave = onSave
        _name = State(initialValue: supplier.name)
        _email = State(initialValue: supplier.email ?? "")
        _phone = State(initialValue: supplier.phone ?? "")
        _address = State(initialValue: supplier.address ?? "")
        _customerNumber = State(initialValue: supplier.customerNumber ?? "")
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Supplier"), text: $name)
                }
                Section {
                    TextField(String(localized: "Email"), text: $email)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField(String(localized: "Phone"), text: $phone)
                        .keyboardType(.phonePad)
                    TextField(String(localized: "Address"), text: $address, axis: .vertical)
                        .lineLimit(2...4)
                    TextField(String(localized: "Customer number"), text: $customerNumber)
                }
            }
            .navigationTitle(String(localized: "Edit Supplier"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        var updated = supplier
                        updated.name = name
                        updated.email = email
                        updated.phone = phone
                        updated.address = address
                        updated.customerNumber = customerNumber
                        Task {
                            await onSave(updated)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
        }
    }
}

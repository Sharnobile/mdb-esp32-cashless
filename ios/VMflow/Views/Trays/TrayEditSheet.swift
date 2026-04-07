import SwiftUI

/// Bottom sheet for editing a tray's configuration: slot number, product, capacity, stock, thresholds.
struct TrayEditSheet: View {
    let machineId: UUID
    let tray: Tray?  // nil = creating new tray
    let products: [Product]
    let onSave: (Int, UUID?, Int, Int, Int, Int) async -> Void
    let onDelete: (() async -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var slotNumber: Int
    @State private var selectedProductId: UUID?
    @State private var capacity: Int
    @State private var currentStock: Int
    @State private var minStock: Int
    @State private var fillWhenBelow: Int
    @State private var isSaving = false
    @State private var showDeleteConfirm = false

    init(
        machineId: UUID,
        tray: Tray?,
        products: [Product],
        onSave: @escaping (Int, UUID?, Int, Int, Int, Int) async -> Void,
        onDelete: (() async -> Void)? = nil
    ) {
        self.machineId = machineId
        self.tray = tray
        self.products = products
        self.onSave = onSave
        self.onDelete = onDelete

        _slotNumber = State(initialValue: tray?.itemNumber ?? 1)
        _selectedProductId = State(initialValue: tray?.productId)
        _capacity = State(initialValue: tray?.capacity ?? 10)
        _currentStock = State(initialValue: tray?.currentStock ?? 0)
        _minStock = State(initialValue: tray?.minStock ?? 0)
        _fillWhenBelow = State(initialValue: tray?.fillWhenBelow ?? 0)
    }

    var isNew: Bool { tray == nil }

    var body: some View {
        NavigationStack {
            Form {
                // Slot Number
                Section("Slot") {
                    Stepper("Slot Number: \(slotNumber)", value: $slotNumber, in: 0...999)
                }

                // Product
                Section("Product") {
                    Picker("Product", selection: $selectedProductId) {
                        Text("None")
                            .tag(UUID?.none)
                        ForEach(products) { product in
                            HStack {
                                ProductImage(imagePath: product.imagePath, size: 24)
                                Text(product.name ?? "Unnamed")
                            }
                            .tag(UUID?.some(product.id))
                        }
                    }
                }

                // Capacity & Stock
                Section("Stock") {
                    Stepper("Capacity: \(capacity)", value: $capacity, in: 1...999)
                    Stepper("Current Stock: \(currentStock)", value: $currentStock, in: 0...capacity)
                    StockBar(current: currentStock, capacity: capacity, height: 10)
                        .padding(.vertical, 4)
                }

                // Thresholds
                Section("Thresholds") {
                    Stepper("Min Stock: \(minStock)", value: $minStock, in: 0...capacity)
                    Stepper("Fill When Below: \(fillWhenBelow)", value: $fillWhenBelow, in: 0...capacity)
                }

                // Delete
                if !isNew, let onDelete {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Spacer()
                                Label("Delete Tray", systemImage: "trash")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add Tray" : "Edit Tray \(slotNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            await onSave(slotNumber, selectedProductId, capacity, currentStock, minStock, fillWhenBelow)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .confirmationDialog("Delete Tray", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        await onDelete?()
                        dismiss()
                    }
                }
            } message: {
                Text("Are you sure you want to delete slot \(slotNumber)?")
            }
        }
    }
}

// MARK: - Batch Add Sheet

/// Sheet for batch-adding sequential tray slots.
struct BatchAddTraySheet: View {
    let machineId: UUID
    let onSave: (Int, Int, Int) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var startSlot = 1
    @State private var count = 5
    @State private var capacity = 10
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Range") {
                    Stepper("Start Slot: \(startSlot)", value: $startSlot, in: 0...999)
                    Stepper("Number of Slots: \(count)", value: $count, in: 1...50)

                    Text("Will create slots \(startSlot) through \(startSlot + count - 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Default Settings") {
                    Stepper("Capacity: \(capacity)", value: $capacity, in: 1...999)
                }
            }
            .navigationTitle("Batch Add Trays")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(count) Trays") {
                        isSaving = true
                        Task {
                            await onSave(startSlot, count, capacity)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }
}

#Preview {
    TrayEditSheet(
        machineId: UUID(),
        tray: nil,
        products: [],
        onSave: { _, _, _, _, _, _ in }
    )
}

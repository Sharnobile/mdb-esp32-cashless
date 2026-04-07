import SwiftUI

/// Packing step: shows machines needing refill as expandable sections with products to pack.
struct PackingStepView: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    @State private var expandedMachineId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    // Warehouse Picker
                    if !viewModel.warehouses.isEmpty {
                        warehousePicker
                    }

                    // Summary header
                    summaryHeader

                    // No machines needing refill
                    if viewModel.machines.isEmpty && !viewModel.isLoading {
                        emptyState
                    } else {
                        // Machine list
                        ForEach(viewModel.machines) { machine in
                            machineSection(machine)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 100) // space for bottom button
            }

            // Bottom Bar
            bottomBar
        }
    }

    // MARK: - Warehouse Picker

    private var warehousePicker: some View {
        HStack {
            Image(systemName: "building.2")
                .foregroundStyle(.secondary)
            Picker("Warehouse", selection: $viewModel.selectedWarehouseId) {
                ForEach(viewModel.warehouses) { warehouse in
                    Text(warehouse.name).tag(UUID?.some(warehouse.id))
                }
            }
            .pickerStyle(.menu)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.fill.tertiary))
        .onChange(of: viewModel.selectedWarehouseId) { _, newValue in
            if let warehouseId = newValue {
                Task { await viewModel.loadWarehouseStock(warehouseId: warehouseId) }
            }
        }
    }

    // MARK: - Summary Header

    private var summaryHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewModel.machines.count) machines need refill")
                    .font(.subheadline.weight(.medium))
                if viewModel.packedMachines.count > 0 {
                    Text("\(viewModel.packedMachines.count) selected, \(viewModel.totalItemsToPack) items to pack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                viewModel.packAllMachines()
            } label: {
                Text("Select All")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Machine Section

    private func machineSection(_ machine: RefillMachine) -> some View {
        VStack(spacing: 0) {
            // Header (tap to toggle packed + expand)
            Button {
                withAnimation(.spring(duration: 0.25)) {
                    if expandedMachineId == machine.id {
                        expandedMachineId = nil
                    } else {
                        expandedMachineId = machine.id
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    // Checkbox
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        viewModel.toggleMachinePacked(machineId: machine.id)
                    } label: {
                        Image(systemName: machine.isPacked ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(machine.isPacked ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(machine.machine.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        HStack(spacing: 8) {
                            Label("\(machine.traysNeedingRefill) trays", systemImage: "tray")
                            Label("\(machine.totalDeficit) items", systemImage: "cube.box")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Urgency indicator
                    urgencyBadge(for: machine)

                    Image(systemName: expandedMachineId == machine.id ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(14)

            // Expanded products
            if expandedMachineId == machine.id {
                Divider()
                    .padding(.leading, 48)

                VStack(spacing: 0) {
                    ForEach(machine.productsNeeded) { item in
                        packingItemRow(item)

                        if item.id != machine.productsNeeded.last?.id {
                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
    }

    // MARK: - Packing Item Row

    private func packingItemRow(_ item: PackingItem) -> some View {
        HStack(spacing: 12) {
            ProductImage(imagePath: item.imagePath, size: 36)

            Text(item.productName)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            // Quantity badge
            Text("\(item.quantity)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.blue.opacity(0.1)))

            // Warehouse stock remaining
            if let stock = viewModel.warehouseStock.first(where: { $0.productId == item.productId }) {
                Text("(\(stock.totalQuantity) in stock)")
                    .font(.caption2)
                    .foregroundStyle(stock.totalQuantity >= item.quantity ? .green : .red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Urgency Badge

    private func urgencyBadge(for machine: RefillMachine) -> some View {
        let emptyCount = machine.trays.filter { $0.tray.isEmpty }.count

        return Group {
            if emptyCount > 0 {
                Text("\(emptyCount) empty")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.red.opacity(0.12)))
            } else {
                Text("Low")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.orange.opacity(0.12)))
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("All Stocked!")
                .font(.title3.weight(.semibold))
            Text("No machines need refilling right now.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 60)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(viewModel.packedMachines.count) machines selected")
                        .font(.subheadline.weight(.medium))
                    Text("\(viewModel.totalItemsToPack) items to pack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.impactOccurred()
                    viewModel.startTour()
                } label: {
                    Label("Start Tour", systemImage: "arrow.right.circle.fill")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.packedMachines.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

#Preview {
    NavigationStack {
        PackingStepView(viewModel: RefillWizardViewModel())
    }
}

import SwiftUI

/// Packing step: product-centric view showing all products needed across machines.
/// Each product card lists which machines need it with per-machine checkboxes.
struct PackingStepView: View {
    @ObservedObject var viewModel: RefillWizardViewModel

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
                    if viewModel.combinedPackingList.isEmpty && !viewModel.isLoading {
                        emptyState
                    } else {
                        // Product list (grouped across machines)
                        ForEach(viewModel.combinedPackingList) { item in
                            productCard(item)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 100)
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
                Text("\(viewModel.combinedPackingList.count) products to pack")
                    .font(.subheadline.weight(.medium))
                Text("\(viewModel.packedMachines.count) of \(viewModel.machines.count) machines ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
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

    // MARK: - Product Card

    private func productCard(_ item: CombinedPackingItem) -> some View {
        let fullyPacked = viewModel.isProductFullyPacked(item)
        // "Out of stock" should mean: nothing left AND nothing packed yet.
        // If the product is fully committed to one or more machines, the
        // remaining stock is 0 but the card is packed, not unusable.
        let outOfStock = !fullyPacked && viewModel.isOutOfWarehouseStock(productId: item.productId)

        return VStack(spacing: 0) {
            // Product header
            Button {
                guard !outOfStock else { return }
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                viewModel.togglePackedAll(productId: item.productId)
            } label: {
                HStack(spacing: 12) {
                    // Checkbox for all machines
                    Image(systemName: outOfStock ? "xmark.circle.fill" :
                            (fullyPacked ? "checkmark.circle.fill" : "circle"))
                        .font(.title3)
                        .foregroundStyle(outOfStock ? .red.opacity(0.5) :
                                        (fullyPacked ? .green : .secondary))

                    ProductImage(imagePath: item.imagePath, size: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.productName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(outOfStock ? .secondary : .primary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            warehouseStockBadge(for: item)

                            if let price = item.formattedSellprice {
                                Text(price)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    // Total quantity — use displayQuantity so unchecked rows
                    // reflect the warehouse cap instead of the raw deficit.
                    let totalQty = item.machineNeeds.reduce(0) { sum, need in
                        sum + viewModel.displayQuantity(machineId: need.machineId, productId: item.productId)
                    }
                    Text("\(totalQty)×")
                        .font(.headline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(outOfStock ? Color.secondary : Color.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(outOfStock ? Color.gray.opacity(0.1) : Color.blue.opacity(0.1)))
                }
            }
            .buttonStyle(.plain)
            .disabled(outOfStock)
            .padding(14)

            Divider()
                .padding(.leading, 14)

            // Machine sub-rows
            VStack(spacing: 0) {
                ForEach(item.machineNeeds) { need in
                    machineNeedRow(item: item, need: need)

                    if need.id != item.machineNeeds.last?.id {
                        Divider()
                            .padding(.leading, 52)
                    }
                }
            }
            .padding(.bottom, 6)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(fullyPacked && !outOfStock ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
        .opacity(outOfStock ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: fullyPacked)
    }

    // MARK: - Machine Need Row

    private func machineNeedRow(item: CombinedPackingItem, need: MachineNeed) -> some View {
        let isPacked = viewModel.isMachinePacked(machineId: need.machineId, productId: item.productId)
        let isDisabled = viewModel.isOutOfStockForMachine(machineId: need.machineId, productId: item.productId)
        // Display the capped quantity for unchecked rows so reducing a tile
        // after an uncheck doesn't suddenly jump up to the raw deficit.
        let qty = viewModel.displayQuantity(machineId: need.machineId, productId: item.productId)
        let maxQty = viewModel.maxPackingQuantity(machineId: need.machineId, productId: item.productId)
        let isPartial = isPacked && maxQty < need.quantity

        return HStack(spacing: 10) {
            // Checkbox
            Button {
                guard !isDisabled else { return }
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                viewModel.togglePackedForMachine(productId: item.productId, machineId: need.machineId)
            } label: {
                Image(systemName: isDisabled ? "xmark.square" :
                        (isPacked ? "checkmark.square.fill" : "square"))
                    .font(.title3)
                    .foregroundStyle(isDisabled ? .red.opacity(0.4) :
                                    (isPacked ? .blue : .secondary))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(isDisabled)

            VStack(alignment: .leading, spacing: 2) {
                Text(need.machineName)
                    .font(.subheadline)
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text("needs \(need.quantity) / \(need.capacity)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if isDisabled {
                        Text("No stock")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.red)
                    } else if isPartial {
                        Text("Partial")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            // Quantity stepper
            HStack(spacing: 6) {
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    viewModel.setPackingQuantity(
                        machineId: need.machineId,
                        productId: item.productId,
                        quantity: qty - 1
                    )
                } label: {
                    Image(systemName: "minus")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.systemGray3), lineWidth: 1.5)
                        )
                        .foregroundStyle(qty > 0 ? .primary : .quaternary)
                }
                .disabled(qty <= 0 || isDisabled)

                Text("\(qty)")
                    .font(.body.weight(.bold))
                    .monospacedDigit()
                    .frame(minWidth: 44, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isDisabled ? Color.gray.opacity(0.1) : Color.blue.opacity(0.1))
                    )
                    .foregroundStyle(isDisabled ? Color.secondary : Color.blue)

                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    viewModel.setPackingQuantity(
                        machineId: need.machineId,
                        productId: item.productId,
                        quantity: qty + 1
                    )
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.systemGray3), lineWidth: 1.5)
                        )
                        .foregroundStyle(qty < maxQty && !isDisabled ? .primary : .quaternary)
                }
                .disabled(qty >= maxQty || isDisabled)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .opacity(isDisabled ? 0.6 : 1.0)
    }

    // MARK: - Warehouse Stock Badge

    @ViewBuilder
    private func warehouseStockBadge(for item: CombinedPackingItem) -> some View {
        if let stock = viewModel.warehouseStockFor(productId: item.productId) {
            let remaining = viewModel.remainingWarehouseStock(productId: item.productId)
            let committed = viewModel.committedQuantity(productId: item.productId)

            if stock.totalQuantity <= 0 {
                Text("Out of Stock")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.red.opacity(0.12)))
            } else if remaining <= 0 && committed > 0 {
                Text("\(committed)/\(stock.totalQuantity) committed")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.orange.opacity(0.12)))
            } else if remaining < item.totalQuantity {
                Text("\(stock.totalQuantity) in stock (\(remaining) left)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.orange.opacity(0.12)))
            } else {
                Text("\(stock.totalQuantity) in stock")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        } else if viewModel.selectedWarehouseId != nil && !viewModel.warehouseStock.isEmpty {
            // Warehouse loaded but this product has zero stock
            Text("Not in warehouse")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.red.opacity(0.12)))
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
                    Text("\(viewModel.packedMachines.count) machines ready")
                        .font(.subheadline.weight(.medium))
                    Text("\(viewModel.totalItemsToPack) items to pack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.impactOccurred()
                    Task { await viewModel.startTour() }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    } else {
                        Label("Start Tour", systemImage: "arrow.right.circle.fill")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.packedMachines.isEmpty || viewModel.isSaving)
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

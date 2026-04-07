import SwiftUI

/// Refill step: shows the current machine being refilled with editable fill amounts.
/// Designed for one-handed use with large touch targets.
struct RefillStepView: View {
    @ObservedObject var viewModel: RefillWizardViewModel

    var body: some View {
        if let machine = viewModel.currentMachine {
            VStack(spacing: 0) {
                // Machine Header with Progress
                machineHeader(machine)

                ScrollView {
                    VStack(spacing: 12) {
                        // Refill All Button
                        Button {
                            let impact = UIImpactFeedbackGenerator(style: .medium)
                            impact.impactOccurred()
                            viewModel.fillAllTrays(machineId: machine.id)
                        } label: {
                            Label("Fill All to Capacity", systemImage: "arrow.up.to.line")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)

                        // Tray List
                        ForEach(machine.trays.filter { $0.deficit > 0 }) { refillTray in
                            refillTrayCard(refillTray, machineId: machine.id)
                        }

                        // Trays that are already full (collapsed)
                        let fullTrays = machine.trays.filter { $0.deficit == 0 }
                        if !fullTrays.isEmpty {
                            DisclosureGroup {
                                ForEach(fullTrays) { tray in
                                    fullTrayRow(tray)
                                }
                            } label: {
                                Text("\(fullTrays.count) trays already full")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 120) // Space for bottom buttons
                }

                // Bottom Action Bar
                bottomActionBar(machine)
            }
        } else {
            // No more machines - should transition to summary
            VStack {
                ProgressView()
                Text("Finishing up...")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Machine Header

    private func machineHeader(_ machine: RefillMachine) -> some View {
        VStack(spacing: 8) {
            // Progress
            HStack {
                Text("Machine \(viewModel.machineProgress.current) of \(viewModel.machineProgress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(machine.traysNeedingRefill) trays to refill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray5))
                    Capsule()
                        .fill(Color.blue)
                        .frame(width: geo.size.width * progressFraction)
                        .animation(.spring(duration: 0.3), value: progressFraction)
                }
            }
            .frame(height: 4)

            // Machine Name
            Text(machine.machine.displayName)
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var progressFraction: Double {
        let progress = viewModel.machineProgress
        guard progress.total > 0 else { return 0 }
        return Double(progress.current - 1) / Double(progress.total)
    }

    // MARK: - Refill Tray Card

    private func refillTrayCard(_ refillTray: RefillTray, machineId: UUID) -> some View {
        VStack(spacing: 12) {
            // Product info
            HStack(spacing: 12) {
                // Slot indicator
                Text("\(refillTray.tray.itemNumber)")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(refillTray.tray.isEmpty ? Color.red : .orange))

                ProductImage(imagePath: refillTray.tray.products?.imagePath, size: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(refillTray.tray.productName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    // Current -> Target
                    HStack(spacing: 4) {
                        Text("\(refillTray.tray.currentStock)")
                            .foregroundStyle(.red)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(refillTray.targetStock)")
                            .foregroundStyle(.green)
                        Text("/ \(refillTray.tray.capacity)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                }

                Spacer()
            }

            // Stock visualization
            HStack(spacing: 8) {
                // Before
                StockBar(
                    current: refillTray.tray.currentStock,
                    capacity: refillTray.tray.capacity,
                    showLabel: false,
                    height: 8
                )
                .frame(maxWidth: .infinity)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // After
                StockBar(
                    current: refillTray.targetStock,
                    capacity: refillTray.tray.capacity,
                    showLabel: false,
                    height: 8
                )
                .frame(maxWidth: .infinity)
            }

            // Fill amount control - LARGE touch targets!
            HStack(spacing: 16) {
                // Decrease
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    viewModel.adjustFillAmount(
                        machineId: machineId,
                        trayId: refillTray.id,
                        amount: refillTray.fillAmount - 1
                    )
                } label: {
                    Image(systemName: "minus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(.fill.tertiary))
                }
                .buttonStyle(.plain)
                .disabled(refillTray.fillAmount <= 0)

                // Amount display
                VStack(spacing: 2) {
                    Text("+\(refillTray.fillAmount)")
                        .font(.title.bold())
                        .monospacedDigit()
                        .foregroundStyle(.blue)
                        .contentTransition(.numericText())
                        .animation(.spring(duration: 0.2), value: refillTray.fillAmount)
                    Text("items")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 70)

                // Increase
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    viewModel.adjustFillAmount(
                        machineId: machineId,
                        trayId: refillTray.id,
                        amount: refillTray.fillAmount + 1
                    )
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(.blue.opacity(0.12)))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .disabled(refillTray.fillAmount >= refillTray.deficit)

                Spacer()

                // Fill to capacity
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.impactOccurred()
                    viewModel.fillTrayToCapacity(machineId: machineId, trayId: refillTray.id)
                } label: {
                    Text("Max")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(.blue))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(refillTray.fillAmount >= refillTray.deficit)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }

    // MARK: - Full Tray Row

    private func fullTrayRow(_ refillTray: RefillTray) -> some View {
        HStack(spacing: 10) {
            Text("\(refillTray.tray.itemNumber)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.green))

            Text(refillTray.tray.productName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Bottom Action Bar

    private func bottomActionBar(_ machine: RefillMachine) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                // Skip button
                Button {
                    viewModel.skipMachine(machineId: machine.id)
                } label: {
                    Text("Skip")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)

                Spacer()

                // Confirm button
                Button {
                    let notification = UINotificationFeedbackGenerator()
                    notification.notificationOccurred(.success)
                    Task {
                        await viewModel.confirmRefill(machineId: machine.id)
                    }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .tint(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    } else {
                        Label("Confirm Refill", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSaving)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

#Preview {
    NavigationStack {
        RefillStepView(viewModel: RefillWizardViewModel())
    }
}

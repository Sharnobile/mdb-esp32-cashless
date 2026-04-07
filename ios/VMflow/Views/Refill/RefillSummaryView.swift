import SwiftUI

/// Summary screen shown after completing a refill tour with statistics and success animation.
struct RefillSummaryView: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    @State private var showCheckmark = false
    @State private var showStats = false
    @State private var showButton = false

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Spacer(minLength: 40)

                // Success Animation
                ZStack {
                    Circle()
                        .fill(.green.opacity(0.1))
                        .frame(width: 120, height: 120)
                        .scaleEffect(showCheckmark ? 1 : 0.3)
                        .opacity(showCheckmark ? 1 : 0)

                    Circle()
                        .fill(.green.opacity(0.2))
                        .frame(width: 90, height: 90)
                        .scaleEffect(showCheckmark ? 1 : 0.3)
                        .opacity(showCheckmark ? 1 : 0)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.green)
                        .scaleEffect(showCheckmark ? 1 : 0)
                        .rotationEffect(showCheckmark ? .zero : .degrees(-90))
                }
                .animation(.spring(duration: 0.6, bounce: 0.4), value: showCheckmark)

                // Title
                VStack(spacing: 8) {
                    Text("Tour Complete!")
                        .font(.title.bold())
                        .opacity(showStats ? 1 : 0)
                        .offset(y: showStats ? 0 : 20)

                    Text("All machines have been refilled")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .opacity(showStats ? 1 : 0)
                        .offset(y: showStats ? 0 : 20)
                }
                .animation(.easeOut(duration: 0.4).delay(0.2), value: showStats)

                // Stats Cards
                VStack(spacing: 12) {
                    statCard(
                        icon: "vending.machine.fill",
                        label: "Machines Visited",
                        value: "\(viewModel.machinesVisited)",
                        color: .blue
                    )

                    statCard(
                        icon: "tray.fill",
                        label: "Trays Refilled",
                        value: "\(viewModel.traysRefilled)",
                        color: .teal
                    )

                    statCard(
                        icon: "cube.box.fill",
                        label: "Total Items Added",
                        value: "\(viewModel.totalItemsAdded)",
                        color: .green
                    )

                    // Skipped machines
                    let skipped = viewModel.machines.filter { $0.isPacked && $0.isSkipped }.count
                    if skipped > 0 {
                        statCard(
                            icon: "forward.fill",
                            label: "Machines Skipped",
                            value: "\(skipped)",
                            color: .orange
                        )
                    }
                }
                .padding(.horizontal)
                .opacity(showStats ? 1 : 0)
                .offset(y: showStats ? 0 : 30)
                .animation(.easeOut(duration: 0.5).delay(0.4), value: showStats)

                // Done Button
                Button {
                    let notification = UINotificationFeedbackGenerator()
                    notification.notificationOccurred(.success)
                    viewModel.reset()
                    Task { await viewModel.loadData() }
                } label: {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .opacity(showButton ? 1 : 0)
                .offset(y: showButton ? 0 : 20)
                .animation(.easeOut(duration: 0.4).delay(0.7), value: showButton)

                Spacer(minLength: 40)
            }
        }
        .onAppear {
            // Trigger haptic
            let notification = UINotificationFeedbackGenerator()
            notification.notificationOccurred(.success)

            // Stagger animations
            withAnimation { showCheckmark = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation { showStats = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation { showButton = true }
            }
        }
    }

    private func statCard(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.1))
                .clipShape(Circle())

            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }
}

#Preview {
    let vm = RefillWizardViewModel()
    vm.machinesVisited = 3
    vm.traysRefilled = 12
    vm.totalItemsAdded = 87

    return NavigationStack {
        RefillSummaryView(viewModel: vm)
    }
}

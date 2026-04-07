import SwiftUI

/// Container for the multi-step refill wizard with step indicator and smooth transitions.
struct RefillWizardView: View {
    @StateObject private var viewModel = RefillWizardViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Step Indicator
            stepIndicator
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(.bar)

            Divider()

            // Step Content
            Group {
                switch viewModel.currentStep {
                case .packing:
                    PackingStepView(viewModel: viewModel)
                case .refill:
                    RefillStepView(viewModel: viewModel)
                case .summary:
                    RefillSummaryView(viewModel: viewModel)
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .animation(.spring(duration: 0.35), value: viewModel.currentStep)
        }
        .navigationTitle("Refill Tour")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadData()
        }
        .overlay {
            if viewModel.isLoading && viewModel.machines.isEmpty {
                ProgressView("Loading machines...")
            }
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.error = nil } }
        )) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(RefillStep.allCases, id: \.rawValue) { step in
                stepBubble(step)

                if step != RefillStep.allCases.last {
                    Rectangle()
                        .fill(step.rawValue < viewModel.currentStep.rawValue ? Color.blue : Color(.systemGray4))
                        .frame(height: 2)
                        .animation(.easeInOut, value: viewModel.currentStep)
                }
            }
        }
    }

    private func stepBubble(_ step: RefillStep) -> some View {
        let isActive = step == viewModel.currentStep
        let isComplete = step.rawValue < viewModel.currentStep.rawValue

        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isComplete ? Color.blue : (isActive ? Color.blue : Color(.systemGray4)))
                    .frame(width: 36, height: 36)

                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: step.icon)
                        .font(.caption)
                        .foregroundStyle(isActive ? .white : .secondary)
                }
            }

            Text(step.title)
                .font(.caption2.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
        }
        .animation(.spring(duration: 0.3), value: viewModel.currentStep)
    }
}

#Preview {
    NavigationStack {
        RefillWizardView()
    }
}

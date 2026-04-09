import SwiftUI

/// Review step: shows discontinued/expired products and lets user pick replacements or skip.
struct ReviewStepView: View {
    @ObservedObject var viewModel: RefillWizardViewModel
    /// Tracks which tray's picker sheet is open (by tray ID).
    @State private var pickerTrayId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    // Header
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title)
                            .foregroundStyle(.orange)
                        Text("Product Review")
                            .font(.title3.bold())
                        Text("The following trays have discontinued, expired, or out-of-stock products. Choose a replacement or skip.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    ForEach(viewModel.replacements) { suggestion in
                        replacementCard(suggestion)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 100)
            }

            // Bottom Bar
            bottomBar
        }
        .sheet(item: $pickerTrayId) { trayId in
            NavigationStack {
                ReplacementProductPicker(
                    products: viewModel.availableProducts,
                    selectedProductId: viewModel.replacements.first(where: { $0.trayId == trayId })?.replacementProductId,
                    onSelect: { productId in
                        viewModel.setReplacement(trayId: trayId, productId: productId)
                        pickerTrayId = nil
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { pickerTrayId = nil }
                    }
                }
            }
            .presentationDetents([.large])
        }
    }

    // MARK: - Replacement Card

    private func replacementCard(_ suggestion: ReplacementSuggestion) -> some View {
        VStack(spacing: 12) {
            // Current product header
            HStack(spacing: 12) {
                // Slot badge
                Text("\(suggestion.slotNumber)")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(badgeColor(for: suggestion.reason)))

                ProductImage(imagePath: suggestion.currentProductImage, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.currentProductName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .strikethrough(true, color: .red)

                    HStack(spacing: 6) {
                        reasonBadge(suggestion.reason)
                        Text(suggestion.machineName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if suggestion.currentStock > 0 {
                        Text("\(suggestion.currentStock) items still in machine")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("0 items in machine")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()
            }

            Divider()

            // Replacement / Skip
            if suggestion.isSkipped {
                HStack {
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(.secondary)
                    Text("Skipped — keeping current product")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") {
                        if let idx = viewModel.replacements.firstIndex(where: { $0.trayId == suggestion.trayId }) {
                            viewModel.replacements[idx].isSkipped = false
                        }
                    }
                    .font(.subheadline.weight(.medium))
                }
            } else if let replacementId = suggestion.replacementProductId,
                      let product = viewModel.availableProducts.first(where: { $0.id == replacementId }) {
                // Already has a replacement selected — tap to change
                Button {
                    pickerTrayId = suggestion.trayId
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(.green)
                        ProductImage(imagePath: product.imagePath, size: 32)
                        Text(product.name ?? "Unknown")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)
                        Spacer()
                        Text("Change")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.blue)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                // Needs action — Replace or Skip
                HStack(spacing: 12) {
                    Button {
                        pickerTrayId = suggestion.trayId
                    } label: {
                        Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        viewModel.skipReplacement(trayId: suggestion.trayId)
                    } label: {
                        Text("Skip")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }

    // MARK: - Reason Badge

    private func badgeColor(for reason: ReplacementReason) -> Color {
        switch reason {
        case .discontinued: return .red
        case .expired: return .orange
        case .noStock: return .purple
        }
    }

    private func reasonBadge(_ reason: ReplacementReason) -> some View {
        let (text, color): (LocalizedStringKey, Color) = {
            switch reason {
            case .discontinued: return ("Discontinued", .red)
            case .expired: return ("Expired", .orange)
            case .noStock: return ("No Stock", .purple)
            }
        }()

        return Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                // Skip all
                Button {
                    Task { await viewModel.skipReview() }
                } label: {
                    Text("Skip Rest")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)

                Spacer()

                // Continue
                Button {
                    Task { await viewModel.applyReplacementsAndContinue() }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                            .tint(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                    } else {
                        let hasReplacements = viewModel.replacements.contains { $0.replacementProductId != nil }
                        Label(
                            hasReplacements ? "Apply & Continue" : "Continue",
                            systemImage: "arrow.right.circle.fill"
                        )
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.allReplacementsHandled || viewModel.isSaving)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

// MARK: - UUID Identifiable for sheet(item:)

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

// MARK: - Replacement Product Picker

struct ReplacementProductPicker: View {
    let products: [Product]
    let selectedProductId: UUID?
    let onSelect: (UUID) -> Void

    @State private var searchText = ""

    private var filteredProducts: [Product] {
        guard !searchText.isEmpty else { return products }
        let query = searchText.lowercased()
        return products
            .compactMap { product -> (Product, Int)? in
                guard let name = product.name?.lowercased() else { return nil }
                if let score = fuzzyMatch(query: query, target: name) {
                    return (product, score)
                }
                return nil
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private func fuzzyMatch(query: String, target: String) -> Int? {
        var score = 0
        var targetIdx = target.startIndex
        var lastMatchIdx: String.Index?

        for ch in query {
            guard let found = target[targetIdx...].firstIndex(of: ch) else { return nil }
            let distance = target.distance(from: targetIdx, to: found)
            if lastMatchIdx != nil { score += distance }
            if lastMatchIdx == nil { score += distance }
            lastMatchIdx = found
            targetIdx = target.index(after: found)
        }
        return score
    }

    var body: some View {
        List {
            ForEach(filteredProducts) { product in
                Button {
                    onSelect(product.id)
                } label: {
                    HStack(spacing: 12) {
                        ProductImage(imagePath: product.imagePath, size: 36)
                        Text(product.name ?? "Unnamed")
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedProductId == product.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }

            if !searchText.isEmpty && filteredProducts.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(Color.clear)
            }
        }
        .searchable(text: $searchText, prompt: "Search products")
        .navigationTitle("Select Replacement")
        .navigationBarTitleDisplayMode(.inline)
    }
}

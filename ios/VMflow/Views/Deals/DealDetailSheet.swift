import SwiftUI

/// Detail sheet showing full deal information with hero image, pin/archive
/// actions, and the full list of matched products / keyword groups. Takes
/// a `DedupedDeal` so the "N matched products" case is rendered properly.
struct DealDetailSheet: View {
    let deal: DedupedDeal
    let onArchive: () -> Void
    let onUnarchive: () -> Void
    let onPin: () -> Void
    let onUnpin: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var primary: Deal { deal.primary }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    heroImage

                    VStack(alignment: .leading, spacing: 16) {
                        titleSection

                        Divider()

                        userActions

                        Divider()

                        priceSection

                        Divider()

                        validitySection

                        if primary.requiresApp {
                            appRequirementNotice
                        }

                        if !deal.matchedKeywords.isEmpty {
                            Divider()
                            keywordsSection
                        }

                        if !deal.matchedProducts.isEmpty {
                            Divider()
                            productsSection
                        }

                        Divider()

                        externalLinks
                    }
                    .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Hero Image

    private var heroImage: some View {
        Group {
            let urlString = primary.imageUrlLarge ?? primary.imageUrl
            if let urlString,
               let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: encoded) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    case .failure:
                        heroPlaceholder
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)
                    @unknown default:
                        heroPlaceholder
                    }
                }
            } else {
                heroPlaceholder
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 250)
        .background(Color(.systemGray6))
    }

    private var heroPlaceholder: some View {
        Image(systemName: "tag.fill")
            .font(.system(size: 48))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 200)
    }

    // MARK: - Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if deal.pinned {
                    Image(systemName: "pin.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
                Text(primary.dealTitle)
                    .font(.title3.weight(.bold))
            }

            HStack(spacing: 6) {
                Image(systemName: "storefront.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text(deal.retailer)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - User actions (pin / archive)

    private var userActions: some View {
        HStack(spacing: 10) {
            pinButton
            archiveButton
        }
    }

    // Split into separate @ViewBuilder properties so each branch can carry
    // its own .buttonStyle — a ternary returning different ButtonStyle
    // concrete types (.bordered vs .borderedProminent) doesn't compile.

    @ViewBuilder
    private var pinButton: some View {
        if deal.pinned {
            Button {
                onUnpin()
            } label: {
                pinLabel
            }
            .buttonStyle(.bordered)
            .tint(Color.accentColor)
        } else {
            Button {
                onPin()
            } label: {
                pinLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
        }
    }

    private var pinLabel: some View {
        Label(
            deal.pinned ? "Unpin" : "Pin to top",
            systemImage: deal.pinned ? "pin.slash.fill" : "pin.fill"
        )
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var archiveButton: some View {
        Button {
            if deal.archived {
                onUnarchive()
            } else {
                onArchive()
                dismiss()
            }
        } label: {
            Label(
                deal.archived ? "Restore" : "Archive",
                systemImage: deal.archived ? "tray.and.arrow.up.fill" : "archivebox.fill"
            )
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
        .tint(deal.archived ? .blue : .orange)
    }

    // MARK: - Price

    private var priceSection: some View {
        HStack(spacing: 12) {
            if let price = primary.formattedDealPrice {
                Text(price)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.green)
            }

            if let regular = primary.formattedRegularPrice {
                Text(regular)
                    .font(.title3)
                    .strikethrough()
                    .foregroundStyle(.secondary)
            }

            if let discount = primary.formattedDiscount {
                Text(discount)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.green))
            }
        }
    }

    // MARK: - Validity

    private var validitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                Text("Validity")
                    .font(.subheadline.weight(.medium))
            }

            HStack(spacing: 8) {
                if let from = primary.formattedValidFrom {
                    Text(from)
                        .font(.subheadline)
                }

                if primary.validFrom != nil && primary.validUntil != nil {
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let until = primary.formattedValidUntil {
                    Text(until)
                        .font(.subheadline)
                }

                Spacer()

                validityStatusBadge
            }
        }
    }

    @ViewBuilder
    private var validityStatusBadge: some View {
        let status = primary.validityStatus
        Text(status.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(validityColor(status))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(validityColor(status).opacity(0.12)))
    }

    // MARK: - App Requirement

    private var appRequirementNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "app.badge.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Requires Loyalty App")
                    .font(.subheadline.weight(.medium))
                Text("This deal may require the retailer's loyalty app or membership card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.08)))
    }

    // MARK: - Matched Keywords

    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                    .foregroundStyle(.secondary)
                Text("Matched Keyword Groups")
                    .font(.subheadline.weight(.medium))
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(deal.matchedKeywords.enumerated()), id: \.offset) { _, kw in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(kw.label ?? kw.terms?.first ?? "Keyword")
                                .font(.subheadline.weight(.medium))
                            if let term = primary.matchedTerm, !term.isEmpty {
                                Text("matched via \"\(term)\"")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if kw.linkedProducts.isEmpty {
                            Text("No products linked to this group yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .italic()
                        } else {
                            ForEach(Array(kw.linkedProducts.enumerated()), id: \.offset) { _, p in
                                if let name = p.name {
                                    Text("• \(name)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
        }
    }

    // MARK: - Matched Products

    private var productsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "cube.box.fill")
                    .foregroundStyle(.secondary)
                Text(deal.matchedProducts.count == 1 ? "Matched Product" : "\(deal.matchedProducts.count) Matched Products")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(primary.formattedConfidence)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(confidenceColor)
            }

            VStack(spacing: 8) {
                ForEach(deal.matchedProducts) { p in
                    HStack(spacing: 12) {
                        ProductImage(imagePath: p.imagePath, size: 36)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                                .font(.subheadline)
                                .lineLimit(2)
                            if let price = p.sellprice {
                                Text(String(format: "%.2f \u{20AC}", price))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Text("\(Int(p.confidence * 100))%")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(confidenceColor(for: p.confidence))
                            .monospacedDigit()
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
        }
    }

    // MARK: - External Links

    private var externalLinks: some View {
        VStack(spacing: 10) {
            if let urlString = primary.sourceUrl, let url = URL(string: urlString) {
                Link(destination: url) {
                    Label("View Prospekt", systemImage: "newspaper")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }

            if let urlString = primary.externalUrl, let url = URL(string: urlString) {
                Link(destination: url) {
                    Label("View All Offers", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Helpers

    private var confidenceColor: Color {
        confidenceColor(for: primary.confidence)
    }

    private func confidenceColor(for value: Double) -> Color {
        switch Deal.ConfidenceLevel(value: value) {
        case .high: return .green
        case .medium: return .yellow
        case .low: return .orange
        }
    }

    private func validityColor(_ status: Deal.ValidityStatus) -> Color {
        switch status {
        case .upcoming: return .blue
        case .active: return .green
        case .expiring: return .orange
        case .expired: return .gray
        }
    }
}

import SwiftUI

/// Detail sheet showing full deal information with hero image and actions.
struct DealDetailSheet: View {
    let deal: Deal
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Hero Image
                    heroImage

                    VStack(alignment: .leading, spacing: 16) {
                        // Title + Retailer
                        titleSection

                        Divider()

                        // Price
                        priceSection

                        Divider()

                        // Validity
                        validitySection

                        // App requirement
                        if deal.requiresApp {
                            appRequirementNotice
                        }

                        Divider()

                        // Matched product
                        productSection

                        Divider()

                        // Actions
                        actionButtons
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
            let urlString = deal.imageUrlLarge ?? deal.imageUrl
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
            Text(deal.dealTitle)
                .font(.title3.weight(.bold))

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

    // MARK: - Price

    private var priceSection: some View {
        HStack(spacing: 12) {
            if let price = deal.formattedDealPrice {
                Text(price)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.green)
            }

            if let regular = deal.formattedRegularPrice {
                Text(regular)
                    .font(.title3)
                    .strikethrough()
                    .foregroundStyle(.secondary)
            }

            if let discount = deal.formattedDiscount {
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
                if let from = deal.formattedValidFrom {
                    Text(from)
                        .font(.subheadline)
                }

                if deal.validFrom != nil && deal.validUntil != nil {
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let until = deal.formattedValidUntil {
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
        let status = deal.validityStatus
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

    // MARK: - Matched Product

    private var productSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "cube.box.fill")
                    .foregroundStyle(.secondary)
                Text("Matched Product")
                    .font(.subheadline.weight(.medium))
            }

            HStack(spacing: 12) {
                ProductImage(imagePath: deal.productImagePath, size: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(deal.productName)
                        .font(.subheadline.weight(.medium))

                    if let price = deal.productSellprice {
                        Text("Sell price: \(String(format: "%.2f \u{20AC}", price))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Confidence
                VStack(spacing: 2) {
                    Text(deal.formattedConfidence)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(confidenceColor)
                    Text("Match")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            if let urlString = deal.sourceUrl, let url = URL(string: urlString) {
                Link(destination: url) {
                    Label("View Prospekt", systemImage: "newspaper")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }

            if let urlString = deal.externalUrl, let url = URL(string: urlString) {
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
        switch deal.confidenceLevel {
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

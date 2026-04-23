import SwiftUI

/// Compact deal card for use in lists. Takes a deduplicated deal (one card
/// per offer, covering all matched products/keyword groups) and surfaces the
/// per-user archive/pin state via small corner badges.
struct DealCard: View {
    let deal: DedupedDeal

    var body: some View {
        HStack(spacing: 12) {
            dealImage

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if deal.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.accentColor)
                    }
                    Text(deal.dealTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }

                HStack(spacing: 4) {
                    Text(deal.retailer)
                        .foregroundStyle(.blue)
                    Text("·")
                        .foregroundStyle(.secondary)
                    matchedTargetLabel
                }
                .font(.caption)
                .lineLimit(1)

                HStack(spacing: 6) {
                    if let price = deal.primary.formattedDealPrice {
                        Text(price)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.green)
                    }

                    if let regular = deal.primary.formattedRegularPrice {
                        Text(regular)
                            .font(.caption)
                            .strikethrough()
                            .foregroundStyle(.secondary)
                    }

                    if let discount = deal.primary.formattedDiscount {
                        Text(discount)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.green))
                    }
                }

                HStack(spacing: 6) {
                    validityBadge

                    if deal.requiresApp {
                        Text("App")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.orange.opacity(0.15)))
                    }

                    if deal.primary.confidenceLevel == .low {
                        Circle()
                            .fill(.yellow)
                            .frame(width: 6, height: 6)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .opacity(deal.archived ? 0.55 : 1.0)
    }

    // MARK: - Matched target label
    // Shows the most informative identifier — a keyword group label (if
    // keyword-matched), a single product name, or an N-matched-products
    // aggregate count. Mirrors the web card.

    @ViewBuilder
    private var matchedTargetLabel: some View {
        if let kw = deal.matchedKeywords.first, let label = kw.label, !label.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "tag.fill")
                    .font(.caption2)
                Text(label)
            }
            .foregroundStyle(.secondary)
        } else if deal.matchedProducts.count > 1 {
            Text("\(deal.matchedProducts.count) matched products")
                .foregroundStyle(.secondary)
        } else if let first = deal.matchedProducts.first {
            Text(first.name)
                .foregroundStyle(.secondary)
        } else {
            Text(deal.primary.productName)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Deal Image

    private var dealImage: some View {
        Group {
            if let urlString = deal.imageUrl ?? deal.imageUrlLarge,
               let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: encoded) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        imagePlaceholder
                    case .empty:
                        ProgressView()
                            .frame(width: 56, height: 56)
                    @unknown default:
                        imagePlaceholder
                    }
                }
            } else {
                imagePlaceholder
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
        )
    }

    private var imagePlaceholder: some View {
        Image(systemName: "tag.fill")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: 56, height: 56)
    }

    // MARK: - Validity Badge

    @ViewBuilder
    private var validityBadge: some View {
        let status = deal.primary.validityStatus
        HStack(spacing: 3) {
            Image(systemName: validityIcon(status))
                .font(.caption2)
            if let until = deal.primary.formattedValidUntil {
                Text("until \(until)")
                    .font(.caption2)
            } else {
                Text(status.label)
                    .font(.caption2)
            }
        }
        .foregroundStyle(validityColor(status))
    }

    private func validityColor(_ status: Deal.ValidityStatus) -> Color {
        switch status {
        case .upcoming: return .blue
        case .active: return .green
        case .expiring: return .orange
        case .expired: return .gray
        }
    }

    private func validityIcon(_ status: Deal.ValidityStatus) -> String {
        switch status {
        case .upcoming: return "clock"
        case .active: return "checkmark.circle"
        case .expiring: return "exclamationmark.triangle"
        case .expired: return "xmark.circle"
        }
    }
}

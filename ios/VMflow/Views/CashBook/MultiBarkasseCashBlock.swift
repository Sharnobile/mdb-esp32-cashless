import SwiftUI

/// Inline list rendered on RefillSummaryView when ≥2 Barkassen with
/// non-zero cash sales were touched by this tour. Each row opens its
/// Barkasse's WithdrawalSheet via the `onSelect` callback.
struct MultiBarkasseCashBlock: View {
    let barkassen: [CashBook]
    let expectedCashFor: (UUID) -> Double
    let onSelect: (CashBook) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "eurosign.circle.fill").foregroundStyle(.green)
                Text("cash_book_after_tour_hint").font(.subheadline.weight(.medium))
            }
            ForEach(barkassen) { cb in
                Button {
                    onSelect(cb)
                } label: {
                    HStack {
                        Text(cb.name).font(.subheadline)
                        Spacer()
                        Text(expectedCashFor(cb.id), format: .currency(code: "EUR"))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                if cb.id != barkassen.last?.id {
                    Divider()
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
        }
    }
}

import SwiftUI

/// Dashboard tile that surfaces the cash-book state at a glance.
struct CashBookCard: View {
    @EnvironmentObject var cashBookVM: CashBookViewModel
    /// Set by the parent to push CashBookView when tapped.
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            content
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "banknote.fill").foregroundStyle(.green)
                Text("cash_book_title").font(.headline)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }

            if cashBookVM.cashBooks.isEmpty {
                Text("cash_book_setup_in_web")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let book = cashBookVM.selectedCashBook {
                FlowVisualisationCard(
                    theoreticalCash: cashBookVM.theoreticalCash,
                    currentBalance: cashBookVM.currentBalance,
                    lastBankDeposit: cashBookVM.lastBankDeposit,
                    bankDepositThreshold: book.bankDepositThreshold,
                    compact: true
                )
                if cashBookVM.currentBalance >= book.bankDepositThreshold {
                    Text("cash_book_deposit_recommended")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                // Multiple, none selected → just the title and "open" hint
                Text(verbatim: "→")
                    .font(.title2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
        .task {
            // Ensure theoretical cash is loaded for the dashboard tile too
            if let id = cashBookVM.selectedCashBookId {
                await cashBookVM.loadTheoreticalCash(for: id)
            }
        }
    }
}

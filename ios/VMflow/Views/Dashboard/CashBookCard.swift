import SwiftUI

/// Dashboard tile that surfaces the cash-book state at a glance.
/// Compact layout: three inline stats (Automaten · Kasse · Bank) + optional reminder.
struct CashBookCard: View {
    @EnvironmentObject var cashBookVM: CashBookViewModel
    /// Set by the parent to push CashBookView when tapped.
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            content
        }
        .buttonStyle(.plain)
        .task {
            // Ensure theoretical cash is loaded for the dashboard tile too
            if let id = cashBookVM.selectedCashBookId {
                await cashBookVM.loadTheoreticalCash(for: id)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "banknote.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
                Text("cash_book_title")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }

            if cashBookVM.cashBooks.isEmpty {
                Text("cash_book_setup_in_web")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let book = cashBookVM.selectedCashBook {
                statsRow

                if cashBookVM.currentBalance >= book.bankDepositThreshold {
                    Text("cash_book_deposit_recommended")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
        }
    }

    @ViewBuilder
    private var statsRow: some View {
        HStack(alignment: .top, spacing: 0) {
            stat(
                titleKey: "cash_book_in_machines",
                valueText: amountText(cashBookVM.theoreticalCash?.cashSalesSince ?? 0),
                accent: (cashBookVM.theoreticalCash?.cashSalesSince ?? 0) > 0.001 ? .orange : .secondary
            )
            divider
            stat(
                titleKey: "cash_book_in_box",
                valueText: amountText(cashBookVM.currentBalance),
                accent: .primary
            )
            divider
            stat(
                titleKey: "cash_book_last_bank_deposit",
                valueText: lastDepositText,
                accent: .secondary
            )
        }
    }

    @ViewBuilder
    private func stat(titleKey: LocalizedStringKey, valueText: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titleKey)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(valueText)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.2))
            .frame(width: 1, height: 28)
            .padding(.horizontal, 6)
    }

    private func amountText(_ value: Double) -> String {
        NumberFormatter.localizedString(from: value as NSNumber, number: .currency)
    }

    private var lastDepositText: String {
        guard let entry = cashBookVM.lastBankDeposit else {
            return NSLocalizedString("cash_book_no_deposit_yet", comment: "")
        }
        let days = Calendar.current.dateComponents([.day], from: entry.createdAt, to: Date()).day ?? 0
        if days == 0 {
            return NSLocalizedString("cash_book_today", comment: "")
        }
        return String(format: NSLocalizedString("cash_book_ago_days", comment: ""), days)
    }
}

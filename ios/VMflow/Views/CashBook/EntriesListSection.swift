import SwiftUI

/// Renders a list of CashBookEntry rows with type badge,
/// amount, balance, optional difference subline, and machine name.
struct EntriesListSection: View {
    let entries: [CashBookEntry]
    let machineName: (UUID?) -> String?

    var body: some View {
        if entries.isEmpty {
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            ForEach(entries) { entry in
                row(for: entry)
            }
        }
    }

    @ViewBuilder
    private func row(for entry: CashBookEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                typeBadge(entry.type, reversed: entry.isReversed)
                Spacer()
                Text(formatAmount(entry.amount))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(entry.amount >= 0 ? Color.green : Color.red)
                Text(entry.balanceAfter, format: .currency(code: "EUR"))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 60, alignment: .trailing)
            }

            HStack {
                Text(entry.createdAt, format: .dateTime.day().month(.twoDigits).hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text(entry.description ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Optional subline: difference (counted vs expected)
            if let counted = entry.countedAmount,
               let expected = entry.expectedAmount,
               abs(counted - expected) > 0.001 {
                Text(differenceText(diff: abs(counted - expected), counted: counted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Optional subline: machine name
            if let mid = entry.machineId, let name = machineName(mid) {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .opacity(entry.isReversed ? 0.5 : 1)
    }

    @ViewBuilder
    private func typeBadge(_ type: CashBookEntryType, reversed: Bool) -> some View {
        let labelKey: LocalizedStringKey
        let color: Color
        switch type {
        case .initial:     labelKey = "cash_book_type_initial";     color = .gray
        case .withdrawal:  labelKey = "cash_book_type_withdrawal";  color = .red
        case .correction:  labelKey = "cash_book_type_correction";  color = .yellow
        case .payout:      labelKey = "cash_book_type_payout";      color = .blue
        case .reversal:    labelKey = "cash_book_type_reversal";    color = .orange
        }

        Text(labelKey)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func formatAmount(_ value: Double) -> String {
        let prefix = value >= 0 ? "+" : ""
        return prefix + (NumberFormatter.localizedString(from: value as NSNumber, number: .currency))
    }

    private func differenceText(diff: Double, counted: Double) -> String {
        let format = NSLocalizedString("cash_book_difference", comment: "")
        let diffStr = NumberFormatter.localizedString(from: diff as NSNumber, number: .currency)
        let countedStr = NumberFormatter.localizedString(from: counted as NSNumber, number: .currency)
        return String(format: format, diffStr, countedStr)
    }
}

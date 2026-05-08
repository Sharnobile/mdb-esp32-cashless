import SwiftUI

struct BankDepositSheet: View {
    let cashBook: CashBook

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var cashBookVM: CashBookViewModel

    /// Raw text for the amount field — supports expressions like
    /// "100+50", "12,50*4". Mirrors WithdrawalSheet / WarehouseView.
    @State private var amountText: String = ""
    @FocusState private var amountFieldFocused: Bool
    @State private var description: String = NSLocalizedString("cash_book_default_deposit_desc", comment: "")
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    /// Evaluated amount (0 when text is empty or invalid).
    private var amount: Double {
        evaluateExpression(amountText) ?? 0
    }

    /// Whether the input contains an operator — drives the "= 25,50 €" preview.
    private var isExpression: Bool {
        amountText.contains(where: { "+-*/×".contains($0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent {
                        Text(cashBookVM.currentBalance, format: .currency(code: "EUR"))
                            .monospacedDigit()
                    } label: {
                        Text("cash_book_current_balance")
                    }
                }

                Section("cash_book_amount_to_bank") {
                    HStack(alignment: .firstTextBaseline) {
                        TextField("0,00", text: $amountText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())
                            .focused($amountFieldFocused)

                        if isExpression, amount > 0 {
                            Text(verbatim: "= \(amountFormatted(amount))")
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.blue)
                        }
                    }

                    Button("cash_book_full_amount") {
                        amountText = formatForInput(cashBookVM.currentBalance)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Section("cash_book_description") {
                    TextField(text: $description) {
                        Text(verbatim: "")
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("cash_book_record_payout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cash_book_cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("cash_book_book_deposit")
                        }
                    }
                    .disabled(isSubmitting || amount <= 0)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if amountFieldFocused {
                        calculatorToolbar
                    }
                }
            }
        }
    }

    // MARK: - Calculator Toolbar

    @ViewBuilder
    private var calculatorToolbar: some View {
        HStack(spacing: 8) {
            ForEach(["×", "+", "-", "/"], id: \.self) { op in
                Button {
                    amountText += op == "×" ? "*" : op
                } label: {
                    Text(op)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .frame(width: 44, height: 36)
                        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                if let result = evaluateExpression(amountText), result > 0 {
                    amountText = formatForInput(result)
                }
                amountFieldFocused = false
            } label: {
                Text("=")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 36)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    /// Evaluates the input as a decimal expression. Accepts:
    /// - direct numbers ("12,50" or "12.50")
    /// - sums/products/divisions ("10+5.50", "12*3", "100/4")
    /// Returns nil for empty / invalid / trailing-operator strings.
    private func evaluateExpression(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)

        if cleaned.isEmpty { return nil }
        if let num = Double(cleaned) { return num }

        let allowed = CharacterSet(charactersIn: "0123456789+-*/.")
        guard cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard let lastChar = cleaned.last, lastChar.isNumber else { return nil }

        let expression = NSExpression(format: cleaned)
        guard let result = expression.expressionValue(with: nil, context: nil) as? NSNumber else {
            return nil
        }
        let value = result.doubleValue
        return value.isFinite && value > 0 ? value : nil
    }

    private func amountFormatted(_ value: Double) -> String {
        NumberFormatter.localizedString(from: value as NSNumber, number: .currency)
    }

    /// Format a Double for inserting back into the text input — uses the
    /// user's locale-aware decimal separator (DE: `,`).
    private func formatForInput(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = false
        return f.string(from: value as NSNumber) ?? String(format: "%.2f", value)
    }

    private func submit() async {
        guard let evaluated = evaluateExpression(amountText), evaluated > 0 else {
            errorMessage = NSLocalizedString("cash_book_amount_to_bank", comment: "")
            return
        }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await cashBookVM.recordBankDeposit(
                cashBookId: cashBook.id,
                amount: evaluated,
                description: description
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

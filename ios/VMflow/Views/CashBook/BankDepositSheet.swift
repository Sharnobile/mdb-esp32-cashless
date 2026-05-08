import SwiftUI

struct BankDepositSheet: View {
    let cashBook: CashBook

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var cashBookVM: CashBookViewModel

    @State private var amount: Decimal = 0
    @State private var description: String = NSLocalizedString("cash_book_default_deposit_desc", comment: "")
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var currentBalance: Decimal {
        Decimal(cashBookVM.currentBalance)
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
                    HStack {
                        TextField(value: $amount, format: .number) {
                            Text(verbatim: "0.00")
                        }
                        .keyboardType(.decimalPad)
                        .monospacedDigit()

                        Button("cash_book_full_amount") {
                            amount = currentBalance
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
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
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let amountDouble = NSDecimalNumber(decimal: amount).doubleValue
            try await cashBookVM.recordBankDeposit(
                cashBookId: cashBook.id,
                amount: amountDouble,
                description: description
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

import SwiftUI

/// Records a cash expense (money OUT of the box for a business purpose).
/// Category + receipt reference are required (GoBD); description is required
/// only for the "other" category.
struct ExpenseSheet: View {
    let cashBook: CashBook

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var cashBookVM: CashBookViewModel

    @State private var amountText: String = ""
    @State private var category: String = "rent"
    @State private var receiptReference: String = ""
    @State private var description: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var amount: Double {
        Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var needsDescription: Bool { category == "other" }

    private var canSubmit: Bool {
        amount > 0
        && !receiptReference.trimmingCharacters(in: .whitespaces).isEmpty
        && (!needsDescription || !description.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("cash_book_amount") {
                    TextField("0,00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospacedDigit())
                }

                Section("cash_book_category") {
                    Picker("cash_book_category", selection: $category) {
                        ForEach(cashBookVM.expenseCategories, id: \.self) { code in
                            let key: String = "cash_book_category_\(code)"
                            Text(LocalizedStringKey(key)).tag(code)
                        }
                    }
                    .labelsHidden()
                }

                Section("cash_book_receipt_reference") {
                    TextField("cash_book_receipt_reference_placeholder", text: $receiptReference)
                }

                Section {
                    TextField(text: $description) { Text(verbatim: "") }
                } header: {
                    Text(needsDescription ? "cash_book_description_required" : "cash_book_description")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("cash_book_record_expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cash_book_cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting { ProgressView() } else { Text("cash_book_book_entry") }
                    }
                    .disabled(isSubmitting || !canSubmit)
                }
            }
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await cashBookVM.recordExpense(
                cashBookId: cashBook.id,
                amount: amount,
                category: category,
                receiptReference: receiptReference.trimmingCharacters(in: .whitespaces),
                description: description.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

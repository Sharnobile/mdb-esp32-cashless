import SwiftUI

struct WithdrawalSheet: View {
    let cashBook: CashBook
    /// Currently used only for analytics/future-proofing; description text is
    /// the same regardless of origin (matches web default exactly).
    let fromTour: Bool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var cashBookVM: CashBookViewModel

    /// Raw text for the counted-amount field — supports expressions like
    /// "10+15.50", "20*3", "100/2". Mirrors the WarehouseView pattern.
    @State private var countedText: String = ""
    @FocusState private var countedFieldFocused: Bool
    @State private var description: String = NSLocalizedString("cash_book_default_withdrawal_desc", comment: "")
    @State private var selectedMachineId: UUID?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    /// Sheet-local copy of TheoreticalCash for the *passed-in* `cashBook`.
    /// Avoids relying on `cashBookVM.theoreticalCash` which may be stale
    /// or for a different Barkasse (multi-Barkasse refill case).
    @State private var theoretical: TheoreticalCash?

    /// Evaluated counted value (0 when text is empty or invalid).
    private var counted: Double {
        evaluateExpression(countedText) ?? 0
    }

    private var difference: Double {
        let expected = theoretical?.cashSalesSince ?? 0
        return counted - expected
    }

    /// Whether the input contains an operator — drives the "= 25,50 €" preview.
    private var isExpression: Bool {
        countedText.contains(where: { "+-*/×".contains($0) })
    }

    /// Machines scoped to *this sheet's* cashBook (not the VM's selected one).
    private var assignedMachines: [CashBookMachineRef] {
        cashBookVM.assignedMachines(for: cashBook.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                expectedSection
                countedSection

                Section("cash_book_description") {
                    TextField(text: $description) {
                        Text(verbatim: "")
                    }
                }

                if cashBook.trackPerMachine && !assignedMachines.isEmpty {
                    Section("cash_book_from_machine") {
                        Picker("cash_book_from_machine", selection: $selectedMachineId) {
                            Text("—").tag(UUID?.none)
                            ForEach(assignedMachines) { m in
                                Text(m.name ?? String(m.id.uuidString.prefix(8)))
                                    .tag(UUID?.some(m.id))
                            }
                        }
                        .labelsHidden()
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("cash_book_record_withdrawal")
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
                            Text("cash_book_book_entry")
                        }
                    }
                    .disabled(isSubmitting || counted <= 0)
                }
            }
            .task {
                // Always load fresh theoretical cash for the cash book this
                // sheet is for — even if the VM's selectedCashBookId points
                // elsewhere (multi-Barkasse refill case).
                await loadTheoretical()
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var expectedSection: some View {
        Section {
            LabeledContent {
                Text(theoretical?.cashSalesSince ?? 0, format: .currency(code: "EUR"))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            } label: {
                Text("cash_book_expected_max")
            }
            if let machines = theoretical?.machines, !machines.isEmpty {
                ForEach(machines) { m in
                    HStack {
                        Text(m.machineName ?? "—").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("+\(NumberFormatter.localizedString(from: m.cashSales as NSNumber, number: .currency))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("cash_book_changer_hint")
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var countedSection: some View {
        Section("cash_book_counted_amount") {
            HStack(alignment: .firstTextBaseline) {
                TextField("0,00", text: $countedText)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .focused($countedFieldFocused)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            if countedFieldFocused {
                                calculatorToolbar
                            }
                        }
                    }

                // Inline evaluated preview when the input is an expression
                if isExpression, counted > 0 {
                    Text(verbatim: "= \(amountFormatted(counted))")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.blue)
                }
            }

            if abs(difference) > 0.001 && counted > 0 {
                Text(differenceLabel)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Calculator Toolbar (matches WarehouseView pattern)

    @ViewBuilder
    private var calculatorToolbar: some View {
        HStack(spacing: 8) {
            ForEach(["×", "+", "-", "/"], id: \.self) { op in
                Button {
                    countedText += op == "×" ? "*" : op
                } label: {
                    Text(op)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .frame(width: 44, height: 36)
                        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            // Evaluate & close keyboard
            Button {
                if let result = evaluateExpression(countedText), result > 0 {
                    countedText = formatForInput(result)
                }
                countedFieldFocused = false
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
        // Normalise: comma → dot (DE keyboards), × → *
        let cleaned = text
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)

        if cleaned.isEmpty { return nil }
        if let num = Double(cleaned) { return num }

        // Allow only digits, operators, and dots
        let allowed = CharacterSet(charactersIn: "0123456789+-*/.")
        guard cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        // Reject expressions ending in an operator
        guard let lastChar = cleaned.last, lastChar.isNumber else { return nil }

        // NSExpression treats integer/integer as integer division. To get
        // proper decimal semantics, append ".0" to integer-looking operands.
        // Simpler: evaluate via NSExpression and read .doubleValue.
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

    private var differenceLabel: String {
        let format = NSLocalizedString("cash_book_difference", comment: "")
        let diffStr = NumberFormatter.localizedString(from: abs(difference) as NSNumber, number: .currency)
        let countedStr = NumberFormatter.localizedString(from: counted as NSNumber, number: .currency)
        return String(format: format, diffStr, countedStr)
    }

    // MARK: - Data + Submit

    private func loadTheoretical() async {
        // If the VM's selection already points at our cashBook, refresh via
        // the VM (so the rest of the app sees the same fresh value) and copy
        // the snapshot. Otherwise do a one-shot RPC to avoid mutating
        // vm.theoreticalCash to the wrong Barkasse.
        if cashBookVM.selectedCashBookId == cashBook.id {
            await cashBookVM.loadTheoreticalCash(for: cashBook.id)
            theoretical = cashBookVM.theoreticalCash
        } else {
            theoretical = await cashBookVM.fetchTheoreticalCash(for: cashBook.id)
        }
    }

    private func submit() async {
        // Final evaluation in case the user submits without tapping "="
        guard let evaluated = evaluateExpression(countedText), evaluated > 0 else {
            errorMessage = NSLocalizedString("cash_book_counted_amount", comment: "")
            return
        }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let expected = theoretical?.cashSalesSince ?? 0
            try await cashBookVM.recordWithdrawal(
                cashBookId: cashBook.id,
                counted: evaluated,
                expected: expected,
                machineId: selectedMachineId,
                description: description
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

import SwiftUI

struct WithdrawalSheet: View {
    let cashBook: CashBook
    /// Currently used only for analytics/future-proofing; description text is
    /// the same regardless of origin (matches web default exactly).
    let fromTour: Bool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var cashBookVM: CashBookViewModel

    @State private var counted: Decimal = 0
    @State private var description: String = NSLocalizedString("cash_book_default_withdrawal_desc", comment: "")
    @State private var selectedMachineId: UUID?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    /// Sheet-local copy of TheoreticalCash for the *passed-in* `cashBook`.
    /// Avoids relying on `cashBookVM.theoreticalCash` which may be stale
    /// or for a different Barkasse (multi-Barkasse refill case).
    @State private var theoretical: TheoreticalCash?

    private var difference: Decimal {
        let expected = Decimal(theoretical?.cashSalesSince ?? 0)
        return counted - expected
    }

    /// Machines scoped to *this sheet's* cashBook (not the VM's selected one).
    private var assignedMachines: [CashBookMachineRef] {
        cashBookVM.assignedMachines(for: cashBook.id)
    }

    var body: some View {
        NavigationStack {
            Form {
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

                Section("cash_book_counted_amount") {
                    TextField(value: $counted, format: .number) {
                        Text(verbatim: "0.00")
                    }
                    .keyboardType(.decimalPad)
                    .monospacedDigit()

                    if abs(difference) > Decimal(0.001) {
                        Text(differenceLabel)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

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

    private var differenceLabel: String {
        let format = NSLocalizedString("cash_book_difference", comment: "")
        let diff = NumberFormatter.localizedString(from: NSDecimalNumber(decimal: abs(difference)), number: .currency)
        let countedStr = NumberFormatter.localizedString(from: NSDecimalNumber(decimal: self.counted), number: .currency)
        return String(format: format, diff, countedStr)
    }

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
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let countedDouble = NSDecimalNumber(decimal: counted).doubleValue
            let expected = theoretical?.cashSalesSince ?? 0
            try await cashBookVM.recordWithdrawal(
                cashBookId: cashBook.id,
                counted: countedDouble,
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

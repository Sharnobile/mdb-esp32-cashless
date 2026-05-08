import SwiftUI

struct CashBookView: View {
    @EnvironmentObject var cashBookVM: CashBookViewModel
    @State private var showWithdrawal = false
    @State private var showDeposit = false

    var body: some View {
        Group {
            if cashBookVM.cashBooks.isEmpty {
                emptyState
            } else if let book = cashBookVM.selectedCashBook {
                content(book: book)
            } else {
                pickerState
            }
        }
        .navigationTitle("cash_book_title")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await cashBookVM.refresh()
        }
        .task {
            // Refresh theoretical cash on every screen open
            if let id = cashBookVM.selectedCashBookId {
                await cashBookVM.loadTheoreticalCash(for: id)
            }
        }
    }

    @ViewBuilder
    private func content(book: CashBook) -> some View {
        List {
            Section {
                FlowVisualisationCard(
                    theoreticalCash: cashBookVM.theoreticalCash,
                    currentBalance: cashBookVM.currentBalance,
                    lastBankDeposit: cashBookVM.lastBankDeposit,
                    bankDepositThreshold: book.bankDepositThreshold,
                    onWithdraw: { showWithdrawal = true },
                    onDeposit: { showDeposit = true }
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }

            // Multi-Barkasse picker (only when multiple exist)
            if cashBookVM.cashBooks.count > 1 {
                Section {
                    Picker(selection: $cashBookVM.selectedCashBookId) {
                        ForEach(cashBookVM.cashBooks) { cb in
                            Text(cb.name).tag(UUID?.some(cb.id))
                        }
                    } label: {
                        Text(verbatim: book.name)
                    }
                }
            }

            Section("cash_book_title") {
                EntriesListSection(
                    entries: cashBookVM.entries,
                    machineName: { cashBookVM.machineName($0) }
                )
            }
        }
        .sheet(isPresented: $showWithdrawal) {
            WithdrawalSheet(cashBook: book, fromTour: false)
                .environmentObject(cashBookVM)
        }
        .sheet(isPresented: $showDeposit) {
            BankDepositSheet(cashBook: book)
                .environmentObject(cashBookVM)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "banknote")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("cash_book_no_barkasse_yet")
                .font(.headline)
            Text("cash_book_setup_in_web")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var pickerState: some View {
        // ≥2 Barkassen, no selection — let the user pick.
        VStack(spacing: 16) {
            Text("cash_book_title").font(.headline)
            ForEach(cashBookVM.cashBooks) { cb in
                Button(cb.name) {
                    cashBookVM.selectedCashBookId = cb.id
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}

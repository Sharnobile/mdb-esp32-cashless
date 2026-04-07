import SwiftUI

/// List/grid of vending machines with search, pull to refresh, and stock urgency sorting.
struct MachineListView: View {
    @StateObject private var viewModel = MachineListViewModel()

    var body: some View {
        ScrollView {
            if viewModel.filteredMachines.isEmpty && !viewModel.isLoading {
                emptyState
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.filteredMachines) { stats in
                        NavigationLink {
                            MachineDetailView(machine: stats.machine, initialStats: stats)
                        } label: {
                            MachineCard(stats: stats)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
        }
        .refreshable {
            await viewModel.loadMachines()
        }
        .searchable(text: $viewModel.searchText, prompt: "Search machines")
        .navigationTitle("Machines")
        .task {
            if viewModel.machines.isEmpty {
                await viewModel.loadMachines()
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.machines.isEmpty {
                ProgressView("Loading machines...")
            }
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.error = nil } }
        )) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "vending.machine")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Machines")
                .font(.title3.weight(.semibold))
            Text("Machines will appear here once registered via the web dashboard.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.top, 80)
    }
}

#Preview {
    NavigationStack {
        MachineListView()
    }
}

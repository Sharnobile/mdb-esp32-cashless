import SwiftUI

/// Main deals view showing matched retailer offers for company products.
struct DealsView: View {
    @StateObject private var viewModel = DealsViewModel()
    @State private var selectedDeal: Deal?

    var body: some View {
        Group {
            if viewModel.settingsLoading && viewModel.deals.isEmpty {
                ProgressView()
            } else if !viewModel.dealsEnabled {
                disabledState
            } else {
                dealsList
            }
        }
        .navigationTitle("Deals")
        .task {
            await viewModel.loadAll()
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.error = nil } }
        )) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
        .sheet(item: $selectedDeal) { deal in
            DealDetailSheet(deal: deal)
                .presentationDetents([.large])
        }
    }

    // MARK: - Disabled State

    private var disabledState: some View {
        VStack(spacing: 20) {
            Image(systemName: "tag.slash")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            Text("Deals Disabled")
                .font(.title2.weight(.bold))

            Text("Enable deal search in Settings to automatically find retailer offers matching your products.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            NavigationLink {
                SettingsView()
            } label: {
                Label("Open Settings", systemImage: "gearshape.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Deals List

    private var dealsList: some View {
        List {
            // KPI Header
            if viewModel.avgDiscount > 0 {
                kpiHeader
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            // Grouping Picker
            Picker("Group by", selection: $viewModel.groupBy) {
                ForEach(DealsViewModel.GroupMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)

            if viewModel.isLoading && viewModel.deals.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("Loading deals...")
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if viewModel.filteredDeals.isEmpty {
                emptyResults
            } else {
                // Grouped deals
                ForEach(viewModel.groupedDeals, id: \.key) { group in
                    Section {
                        ForEach(group.deals) { deal in
                            DealCard(deal: deal)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedDeal = deal
                                }
                        }
                    } header: {
                        HStack {
                            Text(group.key)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(group.deals.count)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Cache indicator
            if viewModel.fromCache {
                HStack {
                    Spacer()
                    Label("Loaded from cache", systemImage: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $viewModel.searchText, prompt: "Search deals...")
        .refreshable {
            await viewModel.fetchDeals(forceRefresh: true)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.fetchDeals(forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }
        }
    }

    // MARK: - KPI Header

    private var kpiHeader: some View {
        HStack(spacing: 12) {
            kpiBadge(
                value: "-\(viewModel.avgDiscount)%",
                label: "Avg",
                icon: "percent",
                color: .green
            )
        }
    }

    private func kpiBadge(value: String, label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty Results

    private var emptyResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No deals found")
                .font(.subheadline.weight(.medium))
            if !viewModel.searchText.isEmpty {
                Text("Try a different search term.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Try refreshing or check your ZIP code in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }
}

#Preview {
    NavigationStack {
        DealsView()
    }
}

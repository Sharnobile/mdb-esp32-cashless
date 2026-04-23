import SwiftUI

/// Main deals view showing matched retailer offers for company products.
/// Deals are deduplicated per (retailer, offer_id) and filtered by the user's
/// archive / pin state. Native iOS swipe-actions on each row give one-tap
/// pin and archive.
struct DealsView: View {
    @StateObject private var viewModel = DealsViewModel()
    @State private var selectedDeal: DedupedDeal?

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
            DealDetailSheet(
                deal: deal,
                onArchive: { Task { await viewModel.archive(deal) } },
                onUnarchive: { Task { await viewModel.unarchive(deal) } },
                onPin: { Task { await viewModel.pin(deal) } },
                onUnpin: { Task { await viewModel.unpin(deal) } }
            )
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
            // Active / Archived picker
            Picker("List mode", selection: $viewModel.listMode) {
                ForEach(DealsViewModel.ListMode.allCases, id: \.self) { mode in
                    if mode == .archived && viewModel.archivedCount > 0 {
                        Text("\(mode.rawValue) (\(viewModel.archivedCount))").tag(mode)
                    } else {
                        Text(mode.rawValue).tag(mode)
                    }
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)

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
                ForEach(viewModel.groupedDeals, id: \.key) { group in
                    Section {
                        ForEach(group.deals) { deal in
                            DealCard(deal: deal)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedDeal = deal
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    pinSwipeButton(for: deal)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    archiveSwipeButton(for: deal)
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
            await viewModel.fetchUserStates()
            await viewModel.fetchDeals(forceRefresh: true)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await viewModel.fetchUserStates()
                        await viewModel.fetchDeals(forceRefresh: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }
        }
    }

    // MARK: - Swipe actions

    @ViewBuilder
    private func pinSwipeButton(for deal: DedupedDeal) -> some View {
        if deal.pinned {
            Button {
                Task { await viewModel.unpin(deal) }
            } label: {
                Label("Unpin", systemImage: "pin.slash.fill")
            }
            .tint(.gray)
        } else {
            Button {
                Task { await viewModel.pin(deal) }
            } label: {
                Label("Pin", systemImage: "pin.fill")
            }
            .tint(Color.accentColor)
        }
    }

    @ViewBuilder
    private func archiveSwipeButton(for deal: DedupedDeal) -> some View {
        if deal.archived {
            Button {
                Task { await viewModel.unarchive(deal) }
            } label: {
                Label("Restore", systemImage: "tray.and.arrow.up.fill")
            }
            .tint(.blue)
        } else {
            Button {
                Task { await viewModel.archive(deal) }
            } label: {
                Label("Archive", systemImage: "archivebox.fill")
            }
            .tint(.orange)
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
            Image(systemName: viewModel.listMode == .archived ? "archivebox" : "magnifyingglass")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(viewModel.listMode == .archived ? "No archived deals" : "No deals found")
                .font(.subheadline.weight(.medium))
            if !viewModel.searchText.isEmpty {
                Text("Try a different search term.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if viewModel.listMode == .archived {
                Text("Archive deals you're not interested in to keep the list focused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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

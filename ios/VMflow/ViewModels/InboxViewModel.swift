import Foundation
import Supabase

/// Drives the iOS Inbox screen — fetches both `machine_feedback` and
/// `product_wishes` rows for the current company (RLS-scoped), merges them
/// into a single timeline, and exposes mark-reviewed / dismiss / delete
/// actions that mirror the web `/inbox` page.
@MainActor
final class InboxViewModel: ObservableObject {
    @Published var items: [InboxItem] = []
    @Published var isLoading = false
    @Published var error: String?

    /// Filter pill state — `nil` = all kinds.
    @Published var kindFilter: InboxItem.Kind? = nil
    /// `true` (default) hides reviewed/dismissed entries.
    @Published var showOnlyOpen = true

    /// Tracks which row is currently being mutated so the UI can dim it.
    @Published var updatingId: UUID?

    private let client = SupabaseService.shared.client

    /// Items after filter pill + open/all toggle. UI binds to this.
    var filteredItems: [InboxItem] {
        items.filter { item in
            if let k = kindFilter, item.kind != k { return false }
            if showOnlyOpen && !item.isOpen { return false }
            return true
        }
    }

    /// Open count of each kind — drives the small badges on the filter pills.
    var openCount: (problem: Int, feedback: Int, wish: Int, total: Int) {
        var p = 0; var f = 0; var w = 0
        for item in items where item.isOpen {
            switch item.kind {
            case .problem:  p += 1
            case .feedback: f += 1
            case .wish:     w += 1
            }
        }
        return (p, f, w, p + f + w)
    }

    // MARK: - Load

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            // Two parallel queries — RLS handles company scoping.
            // Joins on vendingMachine pull the machine name in one round-trip.
            async let feedback: [MachineFeedbackRow] = client
                .from("machine_feedback")
                .select("id, type, message, email, status, created_at, machine_id, vendingMachine(name)")
                .order("created_at", ascending: false)
                .limit(200)
                .execute()
                .value

            async let wishes: [ProductWishRow] = client
                .from("product_wishes")
                .select("id, wish_text, email, status, created_at, machine_id, vendingMachine(name)")
                .order("created_at", ascending: false)
                .limit(200)
                .execute()
                .value

            let (fbRows, wishRows) = try await (feedback, wishes)

            let merged = fbRows.compactMap(InboxItem.init) + wishRows.compactMap(InboxItem.init)
            items = merged.sorted { $0.createdAt > $1.createdAt }

            // Update the icon badge from the same data we just fetched —
            // saves an extra round-trip when the user opens the Inbox screen.
            await NotificationService.shared.refreshBadge()
        } catch is CancellationError {
            // ignore
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Mutations

    func markReviewed(_ item: InboxItem) async {
        await updateStatus(item, to: .reviewed)
    }

    func markDismissed(_ item: InboxItem) async {
        await updateStatus(item, to: .dismissed)
    }

    func reopen(_ item: InboxItem) async {
        await updateStatus(item, to: .new)
    }

    private func updateStatus(_ item: InboxItem, to status: InboxItem.Status) async {
        guard updatingId == nil else { return }
        updatingId = item.id
        defer { updatingId = nil }

        do {
            try await client
                .from(item.source.rawValue)
                .update(["status": status.rawValue])
                .eq("id", value: item.id.uuidString)
                .execute()

            // Optimistic local replace — avoids a full reload.
            if let idx = items.firstIndex(where: { $0.id == item.id && $0.source == item.source }) {
                let updated = InboxItem(
                    id: item.id,
                    source: item.source,
                    kind: item.kind,
                    message: item.message,
                    email: item.email,
                    status: status,
                    createdAt: item.createdAt,
                    machineId: item.machineId,
                    machineName: item.machineName
                )
                items[idx] = updated
            }
            await NotificationService.shared.refreshBadge()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(_ item: InboxItem) async {
        guard updatingId == nil else { return }
        updatingId = item.id
        defer { updatingId = nil }

        do {
            try await client
                .from(item.source.rawValue)
                .delete()
                .eq("id", value: item.id.uuidString)
                .execute()
            items.removeAll { $0.id == item.id && $0.source == item.source }
            await NotificationService.shared.refreshBadge()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

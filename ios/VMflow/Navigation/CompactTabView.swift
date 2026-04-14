import SwiftUI

/// iPhone tab bar layout — preserves the original 5-tab navigation exactly.
struct CompactTabView: View {
    @EnvironmentObject var auth: AuthService
    @StateObject private var notificationService = NotificationService.shared
    @State private var selectedTab: AppTab = .dashboard

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                DashboardView(onNavigate: { item in
                    if let tab = item.compactTab {
                        selectedTab = tab
                    }
                })
            }
            .tabItem {
                Label("Dashboard", systemImage: "chart.bar.fill")
            }
            .tag(AppTab.dashboard)

            NavigationStack {
                MachineListView()
            }
            .tabItem {
                Label("Machines", systemImage: "storefront.fill")
            }
            .tag(AppTab.machines)

            NavigationStack {
                RefillWizardView()
            }
            .tabItem {
                Label("Refill", systemImage: "arrow.clockwise.circle.fill")
            }
            .tag(AppTab.refill)

            NavigationStack {
                InboxView()
            }
            .tabItem {
                Label("Inbox", systemImage: "tray.fill")
            }
            .badge(notificationService.openInboxCount)
            .tag(AppTab.inbox)

            NavigationStack {
                MoreView()
            }
            .tabItem {
                Label("More", systemImage: "ellipsis.circle.fill")
            }
            .tag(AppTab.more)
        }
        .tint(.blue)
        // Notification tap deep-link routing.
        .onChange(of: notificationService.pendingDeepLink) { _, link in
            guard let link else { return }
            switch link {
            case .inbox:
                selectedTab = .inbox
            }
            notificationService.pendingDeepLink = nil
        }
    }
}

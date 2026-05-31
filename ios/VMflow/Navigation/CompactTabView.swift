import SwiftUI

/// iPhone tab bar layout — preserves the original 5-tab navigation exactly.
struct CompactTabView: View {
    @EnvironmentObject var auth: AuthService
    @StateObject private var notificationService = NotificationService.shared
    @State private var selectedTab: AppTab = .dashboard
    /// Deep-link target for the More tab — lets the dashboard open a More
    /// destination (e.g. Deals) when its banner is tapped.
    @State private var moreDeepLink: SidebarItem?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                DashboardView(onNavigate: { item in
                    if let tab = item.compactTab {
                        selectedTab = tab
                    } else {
                        // Destinations under "More" (deals, products, …):
                        // switch to the More tab and push the destination.
                        moreDeepLink = item
                        selectedTab = .more
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
                WarehouseView()
            }
            .tabItem {
                Label("Warehouse", systemImage: "shippingbox.fill")
            }
            .tag(AppTab.warehouse)

            MoreView(deepLink: $moreDeepLink)
            .tabItem {
                Label("More", systemImage: "ellipsis.circle.fill")
            }
            .tag(AppTab.more)
        }
        .tint(.blue)
        // Notification tap deep-link routing. Inbox now lives under the More
        // tab, so route there and push the Inbox destination.
        .onChange(of: notificationService.pendingDeepLink) { _, link in
            guard let link else { return }
            switch link {
            case .inbox:
                moreDeepLink = .inbox
                selectedTab = .more
            }
            notificationService.pendingDeepLink = nil
        }
    }
}

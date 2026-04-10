import SwiftUI

@main
struct VMflowApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var authService = AuthService()

    init() {
        #if DEBUG
        LocalNetworkPermission.shared.trigger()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
        }
    }
}

// MARK: - Root View (Auth Router)

/// Routes between authentication and main app based on auth state.
struct RootView: View {
    @EnvironmentObject var auth: AuthService

    var body: some View {
        Group {
            if auth.isLoading {
                LaunchScreenView()
            } else if !auth.isAuthenticated {
                AuthNavigationView()
            } else if auth.organization == nil {
                NoOrganizationView()
            } else {
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: auth.isAuthenticated)
        .animation(.easeInOut(duration: 0.3), value: auth.isLoading)
    }
}

// MARK: - Launch Screen

struct LaunchScreenView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            Text("VMflow")
                .font(.largeTitle.bold())
            ProgressView()
                .padding(.top, 8)
        }
    }
}

// MARK: - No Organization

struct NoOrganizationView: View {
    @EnvironmentObject var auth: AuthService

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "building.2")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No Organization")
                .font(.title2.bold())
            Text("You are not a member of any organization yet. Please create or join one using the web dashboard.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
            Button("Sign Out") {
                Task { await auth.logout() }
            }
            .buttonStyle(.bordered)
            Button("Retry") {
                Task { await auth.fetchOrganization() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Auth Navigation

struct AuthNavigationView: View {
    var body: some View {
        NavigationStack {
            LoginView()
        }
    }
}

// MARK: - Tab Selection

enum AppTab: Hashable {
    case dashboard, machines, refill, inbox, more
}

// MARK: - Main Tab View

struct MainTabView: View {
    @EnvironmentObject var auth: AuthService
    @StateObject private var realtime = RealtimeService.shared
    @StateObject private var notificationService = NotificationService.shared
    @State private var selectedTab: AppTab = .dashboard
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                DashboardView(selectedTab: $selectedTab)
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
        .environmentObject(realtime)
        .task {
            realtime.start()
            await NotificationService.shared.setupAfterLogin()
        }
        // App returns to foreground → refresh badge from server.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await NotificationService.shared.refreshBadge() }
            }
        }
        // Notification tap deep-link routing.
        .onChange(of: notificationService.pendingDeepLink) { _, link in
            guard let link = link else { return }
            switch link {
            case .inbox:
                selectedTab = .inbox
            }
            notificationService.pendingDeepLink = nil
        }
    }
}

// MARK: - More View

struct MoreView: View {
    @EnvironmentObject var auth: AuthService

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ProductsView()
                } label: {
                    Label("Products", systemImage: "cube.box.fill")
                }

                NavigationLink {
                    WarehouseView()
                } label: {
                    Label("Warehouse", systemImage: "shippingbox.fill")
                }
            }

            Section {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                }
            }
        }
        .navigationTitle("More")
    }
}

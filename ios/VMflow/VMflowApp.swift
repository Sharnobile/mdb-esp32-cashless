import SwiftUI

@main
struct VMflowApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var authService = AuthService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        LocalNetworkPermission.shared.trigger()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await authService.syncLocaleToServer() }
                    }
                }
                .task {
                    for await _ in NotificationCenter.default.notifications(
                        named: NSLocale.currentLocaleDidChangeNotification
                    ) {
                        await authService.syncLocaleToServer()
                    }
                }
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
                AdaptiveRootView()
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
            Image("AppLogo")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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

// MARK: - More View

struct MoreView: View {
    @EnvironmentObject var auth: AuthService

    /// Deep-link target set by the dashboard (e.g. its "new deals" banner).
    /// Drives a programmatic NavigationLink so a banner tap on the Dashboard
    /// tab can open a destination that lives under More.
    @Binding var deepLink: SidebarItem?

    init(deepLink: Binding<SidebarItem?> = .constant(nil)) {
        self._deepLink = deepLink
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CashBookView()
                    } label: {
                        Label {
                            Text("cash_book_title")
                        } icon: {
                            Image(systemName: "banknote.fill")
                        }
                    }

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

                    NavigationLink {
                        DealsView()
                    } label: {
                        Label("Deals", systemImage: "tag.fill")
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
            // Programmatic deep-link: dashboard banner → a More destination.
            .navigationDestination(item: $deepLink) { item in
                switch item {
                case .deals:     DealsView()
                case .products:  ProductsView()
                case .warehouse: WarehouseView()
                case .cashBook:  CashBookView()
                case .settings:  SettingsView()
                default:         EmptyView()
                }
            }
        }
    }
}

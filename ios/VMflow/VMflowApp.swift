import SwiftUI

@main
struct VMflowApp: App {
    @StateObject private var authService = AuthService()

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

// MARK: - Main Tab View

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                DashboardView()
            }
            .tabItem {
                Label("Dashboard", systemImage: "chart.bar.fill")
            }

            NavigationStack {
                MachineListView()
            }
            .tabItem {
                Label("Machines", systemImage: "vending.machine.fill")
            }

            NavigationStack {
                RefillWizardView()
            }
            .tabItem {
                Label("Refill", systemImage: "arrow.clockwise.circle.fill")
            }
        }
        .tint(.blue)
    }
}

import SwiftUI

/// Routes between compact tab layout (iPhone) and sidebar layout (iPad/Mac)
/// based on horizontal size class.
struct AdaptiveRootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @EnvironmentObject var auth: AuthService
    @StateObject private var realtime = RealtimeService.shared
    @StateObject private var notificationService = NotificationService.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if sizeClass == .compact {
                CompactTabView()
            } else {
                SidebarNavigationView()
            }
        }
        .environmentObject(realtime)
        .task {
            realtime.start()
            await NotificationService.shared.setupAfterLogin()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await NotificationService.shared.refreshBadge() }
            }
        }
    }
}

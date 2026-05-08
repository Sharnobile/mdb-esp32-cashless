import SwiftUI

/// Routes between compact tab layout (iPhone) and sidebar layout (iPad/Mac)
/// based on horizontal size class.
struct AdaptiveRootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @EnvironmentObject var auth: AuthService
    @StateObject private var realtime = RealtimeService.shared
    @StateObject private var notificationService = NotificationService.shared
    @StateObject private var cashBookVM = CashBookViewModel()
    @AppStorage("selected_barkasse_id") private var selectedBarkasseIDRaw: String = ""
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
        .environmentObject(cashBookVM)
        .task {
            realtime.start()
            await NotificationService.shared.setupAfterLogin()

            // Restore persisted selection, then refresh
            if let uuid = UUID(uuidString: selectedBarkasseIDRaw) {
                cashBookVM.selectedCashBookId = uuid
            }
            await cashBookVM.refresh()
            // Persist post-reconciliation
            selectedBarkasseIDRaw = cashBookVM.selectedCashBookId?.uuidString ?? ""
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await NotificationService.shared.refreshBadge()
                    await cashBookVM.refresh()
                    selectedBarkasseIDRaw = cashBookVM.selectedCashBookId?.uuidString ?? ""
                }
            }
        }
        .onChange(of: cashBookVM.selectedCashBookId) { _, newValue in
            selectedBarkasseIDRaw = newValue?.uuidString ?? ""
        }
    }
}

import UIKit
import UserNotifications

/// Minimal AppDelegate to handle push notification registration callbacks.
/// SwiftUI doesn't natively expose `didRegisterForRemoteNotificationsWithDeviceToken`,
/// so we bridge via `UIApplicationDelegateAdaptor`.
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // MARK: - Remote Notification Registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("[Push] Device token: \(token)")
        Task { @MainActor in
            NotificationService.shared.handleDeviceToken(token)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[Push] Registration failed: \(error)")
        Task { @MainActor in
            NotificationService.shared.handleRegistrationError(error)
        }
    }

    // MARK: - Foreground Notification Display

    /// Show banner + sound even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    // MARK: - Notification Tap Handling

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if let type = userInfo["type"] as? String {
            print("[Push] Notification tapped: type=\(type)")
            await MainActor.run {
                NotificationService.shared.handleNotificationTap(type: type, userInfo: userInfo)
            }
        }
    }
}

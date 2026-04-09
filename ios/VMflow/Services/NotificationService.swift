import Foundation
import UserNotifications
import UIKit
import Supabase

// MARK: - Models

struct NotificationPreference: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    let notificationType: String
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case notificationType = "notification_type"
        case enabled
    }
}

struct NotificationType: Identifiable {
    let key: String
    let label: String
    let description: String
    let icon: String

    var id: String { key }
}

// MARK: - Service

/// Manages push notification permissions, device registration, and per-type preferences.
@MainActor
final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    // MARK: - Published State

    @Published var isEnabled: Bool = false
    @Published var permissionStatus: UNAuthorizationStatus = .notDetermined
    @Published var preferences: [NotificationPreference] = []
    @Published var deviceToken: String?
    @Published var isRegistering: Bool = false
    @Published var error: String?

    /// Available notification types (matches web UI).
    static let notificationTypes: [NotificationType] = [
        NotificationType(
            key: "sale",
            label: "Sale Notifications",
            description: "Get notified for every vending machine sale",
            icon: "cart.fill"
        ),
        NotificationType(
            key: "low_stock",
            label: "Low Stock Alerts",
            description: "Get notified when a product drops below the refill threshold",
            icon: "exclamationmark.triangle.fill"
        ),
    ]

    private let client = SupabaseService.shared.client
    /// Key for persisting the last registered token to detect changes.
    private let tokenKey = "apns-device-token"

    private init() {}

    // MARK: - Permission

    /// Check current notification permission status without prompting.
    func checkPermissionStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permissionStatus = settings.authorizationStatus
        isEnabled = settings.authorizationStatus == .authorized
    }

    /// Request notification permission and register for remote notifications if granted.
    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await checkPermissionStatus()
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
            return granted
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Device Token

    /// Called by AppDelegate when APNs registration succeeds.
    func handleDeviceToken(_ token: String) {
        let previousToken = UserDefaults.standard.string(forKey: tokenKey)
        self.deviceToken = token

        // Only re-register if token changed or never registered
        if token != previousToken {
            Task { await registerWithBackend(token: token) }
        }
    }

    /// Called by AppDelegate when APNs registration fails.
    func handleRegistrationError(_ error: Error) {
        print("[Push] Registration error: \(error)")
        // Don't show error for simulator (push not supported)
        #if !targetEnvironment(simulator)
        self.error = "Push registration failed"
        #endif
    }

    /// Register this device's APNs token with the backend.
    private func registerWithBackend(token: String) async {
        isRegistering = true
        defer { isRegistering = false }

        do {
            struct RegisterBody: Encodable {
                let fcm_token: String
                let platform: String
                let bundle_id: String?
            }

            try await client.functions.invoke(
                "register-push",
                options: .init(body: RegisterBody(
                    fcm_token: token,
                    platform: "ios",
                    bundle_id: Bundle.main.bundleIdentifier
                ))
            )

            UserDefaults.standard.set(token, forKey: tokenKey)
            print("[Push] Registered device token with backend")
        } catch {
            print("[Push] Backend registration failed: \(error)")
            self.error = "Failed to register for push notifications"
        }
    }

    /// Unregister this device from push notifications.
    /// Best-effort: if the user is already logged out (401), we still clean up locally.
    /// The server-side subscription becomes stale but is auto-cleaned on next failed push.
    func unregisterDevice() async {
        guard let token = deviceToken ?? UserDefaults.standard.string(forKey: tokenKey) else { return }

        // Only attempt server-side removal if we have a valid session
        if let _ = try? await client.auth.session {
            do {
                struct UnregisterBody: Encodable {
                    let fcm_token: String
                }

                try await client.functions.invoke(
                    "register-push",
                    options: .init(method: .delete, body: UnregisterBody(fcm_token: token))
                )
                print("[Push] Unregistered device from server")
            } catch {
                // 401 is expected during logout — ignore silently
                print("[Push] Server unregister skipped (session likely expired)")
            }
        }

        // Always clean up locally
        UserDefaults.standard.removeObject(forKey: tokenKey)
        deviceToken = nil
        isEnabled = false
    }

    // MARK: - Notification Preferences

    /// Fetch the user's per-type notification preferences.
    func fetchPreferences() async {
        do {
            preferences = try await client
                .from("notification_preferences")
                .select("id, user_id, notification_type, enabled")
                .execute()
                .value
        } catch is CancellationError {
        } catch {
            print("[Push] Failed to fetch preferences: \(error)")
        }
    }

    /// Whether a given notification type is enabled. Defaults to `true` if no preference row exists.
    func isTypeEnabled(_ type: String) -> Bool {
        guard let pref = preferences.first(where: { $0.notificationType == type }) else {
            return true
        }
        return pref.enabled
    }

    /// Toggle a notification type on or off. Upserts to `notification_preferences`.
    func togglePreference(type: String, enabled: Bool) async {
        do {
            let userId = try await client.auth.session.user.id

            try await client
                .from("notification_preferences")
                .upsert(
                    [
                        "user_id": AnyJSON.string(userId.uuidString),
                        "notification_type": AnyJSON.string(type),
                        "enabled": AnyJSON.bool(enabled),
                        "updated_at": AnyJSON.string(ISO8601DateFormatter().string(from: Date())),
                    ],
                    onConflict: "user_id,notification_type"
                )
                .execute()

            await fetchPreferences()
        } catch {
            print("[Push] Failed to toggle preference: \(error)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Test Notification

    /// Send a test push notification to this device via the backend.
    func sendTestNotification() async {
        do {
            try await client.functions.invoke(
                "test-push",
                options: .init(method: .post)
            )
        } catch {
            self.error = "Test notification failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Notification Tap Handling

    /// Handle taps on received notifications. Can be extended for deep linking.
    func handleNotificationTap(type: String, userInfo: [AnyHashable: Any]) {
        // Deep linking can be added here in the future.
        // For now, just log the event.
        print("[Push] Handle tap: type=\(type), data=\(userInfo)")
    }

    // MARK: - Lifecycle

    /// Call after successful login to set up push notifications.
    func setupAfterLogin() async {
        await checkPermissionStatus()

        if permissionStatus == .authorized {
            UIApplication.shared.registerForRemoteNotifications()
        }

        await fetchPreferences()
    }

    /// Call on logout to clean up.
    func cleanupOnLogout() async {
        await unregisterDevice()
        preferences = []
    }
}

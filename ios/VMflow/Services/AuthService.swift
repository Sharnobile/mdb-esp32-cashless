import Foundation
import Supabase
import Combine

/// Manages authentication state and user session via Supabase Auth.
/// Published properties drive the app's auth-dependent UI.
@MainActor
final class AuthService: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isLoading = true
    @Published var organization: Organization?
    @Published var role: OrganizationRole?
    @Published var error: String?

    private var client: SupabaseClient { SupabaseService.shared.client }
    private var authStateTask: Task<Void, Never>?

    init() {
        startAuthListener()
    }

    /// (Re)start the auth state change listener on the current Supabase client.
    /// Called on init and after server reconfiguration.
    func restartAuthListener() {
        authStateTask?.cancel()
        startAuthListener()
    }

    private func startAuthListener() {
        authStateTask = Task { [weak self] in
            guard let self else { return }
            await self.checkSession()
            for await (event, _) in self.client.auth.authStateChanges {
                switch event {
                case .signedIn:
                    self.isAuthenticated = true
                    await self.fetchOrganization()
                    Task { await self.syncLocaleToServer() }
                case .signedOut:
                    self.isAuthenticated = false
                    self.organization = nil
                    self.role = nil
                default:
                    break
                }
                self.isLoading = false
            }
        }
    }

    deinit {
        authStateTask?.cancel()
    }

    // MARK: - Session

    /// Check for an existing session on app launch.
    func checkSession() async {
        isLoading = true
        do {
            let session = try await client.auth.session
            isAuthenticated = true
            _ = session
            await fetchOrganization()
            Task { await self.syncLocaleToServer() }
        } catch {
            isAuthenticated = false
        }
        isLoading = false
    }

    // MARK: - Login

    /// Sign in with email and password.
    func login(email: String, password: String) async {
        error = nil
        isLoading = true
        do {
            try await client.auth.signIn(email: email, password: password)
            isAuthenticated = true
            await fetchOrganization()
            Task { await self.syncLocaleToServer() }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Register

    /// Create a new account with email and password.
    func register(email: String, password: String, firstName: String, lastName: String) async {
        error = nil
        isLoading = true
        do {
            try await client.auth.signUp(
                email: email,
                password: password,
                data: [
                    "first_name": .string(firstName),
                    "last_name": .string(lastName)
                ]
            )
            isAuthenticated = true
            await fetchOrganization()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Logout

    /// Sign out and clear state.
    func logout() async {
        do {
            try await client.auth.signOut()
        } catch {
            // Ignore sign-out errors — clear local state regardless
        }
        isAuthenticated = false
        organization = nil
        role = nil
    }

    // MARK: - Locale sync

    /// Read the device's primary language code and persist it to
    /// `public.users.locale` (clamped to "en" / "de"). Idempotent: caches
    /// the last-synced value in UserDefaults and skips the write if
    /// unchanged. Best-effort — failures log but never surface to the user.
    ///
    /// Call on: successful login, scene phase `.active`, and on the
    /// `NSLocale.currentLocaleDidChangeNotification`.
    func syncLocaleToServer() async {
        let deviceCode = Locale.current.language.languageCode?.identifier ?? "en"
        let locale = (deviceCode.lowercased() == "de") ? "de" : "en"

        let cacheKey = "vmflow-last-synced-locale"
        if UserDefaults.standard.string(forKey: cacheKey) == locale {
            return
        }

        do {
            let userId = try await client.auth.session.user.id
            try await client.from("users")
                .update(["locale": locale])
                .eq("id", value: userId)
                .execute()
            UserDefaults.standard.set(locale, forKey: cacheKey)
            print("[Locale] Synced user locale to \(locale)")
        } catch {
            print("[Locale] Sync failed (best-effort): \(error)")
        }
    }

    // MARK: - Organization

    /// Fetch the user's organization via the `get-my-organization` edge function.
    func fetchOrganization() async {
        do {
            print("[AuthService] Fetching organization from \(SupabaseService.shared.supabaseURL)/functions/v1/get-my-organization")
            let response: OrganizationResponse = try await client.functions.invoke(
                "get-my-organization",
                options: .init(method: .get)
            )
            print("[AuthService] Response: org=\(String(describing: response.organization?.name)), role=\(String(describing: response.role))")
            organization = response.organization
            if let roleString = response.role {
                role = OrganizationRole(rawValue: roleString)
            }
        } catch {
            print("[AuthService] fetchOrganization error: \(error)")
            organization = nil
            role = nil
        }
    }

    /// The current access token for API calls.
    var accessToken: String? {
        get async {
            try? await client.auth.session.accessToken
        }
    }
}

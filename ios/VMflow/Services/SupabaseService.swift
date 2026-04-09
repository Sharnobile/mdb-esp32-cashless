import Foundation
import Supabase

// MARK: - Configuration

/// App configuration read from Info.plist at runtime.
/// Values are injected via xcconfig files (Debug.xcconfig / Release.xcconfig).
enum AppConfig {
    static var supabaseURL: URL {
        guard let scheme = Bundle.main.infoDictionary?["SUPABASE_SCHEME"] as? String,
              let host = Bundle.main.infoDictionary?["SUPABASE_HOST"] as? String,
              !scheme.isEmpty, !host.isEmpty,
              let url = URL(string: "\(scheme)://\(host)") else {
            fatalError("SUPABASE_SCHEME / SUPABASE_HOST not configured in Info.plist")
        }
        return url
    }

    static var supabaseAnonKey: String {
        guard let key = Bundle.main.infoDictionary?["SUPABASE_ANON_KEY"] as? String, !key.isEmpty else {
            fatalError("SUPABASE_ANON_KEY not configured in Info.plist")
        }
        return key
    }
}

// MARK: - Supabase Service

/// Singleton providing the configured Supabase client instance.
/// All services and view models access Supabase through this shared client.
/// @MainActor ensures reconfigure() is only called from the main thread.
@MainActor
final class SupabaseService {
    static let shared = SupabaseService()

    private(set) var client: SupabaseClient
    private(set) var supabaseURL: URL

    private init() {
        let server = ServerStore.shared.selectedServer
        let url = URL(string: server.sanitizedURL) ?? AppConfig.supabaseURL
        supabaseURL = url
        client = SupabaseClient(supabaseURL: url, supabaseKey: server.anonKey)
    }

    /// Recreate the Supabase client with new server credentials.
    /// Must only be called from the login screen when no active sessions exist.
    func reconfigure(url: URL, anonKey: String) {
        supabaseURL = url
        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }
}

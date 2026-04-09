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
final class SupabaseService {
    static let shared = SupabaseService()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: AppConfig.supabaseURL,
            supabaseKey: AppConfig.supabaseAnonKey
        )
    }
}

import Foundation
import Supabase

// MARK: - Configuration

/// App configuration read from Info.plist at runtime.
/// Set `SUPABASE_URL` and `SUPABASE_ANON_KEY` in your Info.plist or xcconfig.
enum AppConfig {
    static var supabaseURL: URL {
        guard let urlString = Bundle.main.infoDictionary?["SUPABASE_URL"] as? String,
              let url = URL(string: urlString) else {
            fatalError("SUPABASE_URL not configured in Info.plist")
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

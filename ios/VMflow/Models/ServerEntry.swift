import Foundation

struct ServerEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var anonKey: String
    let isDefault: Bool

    var sanitizedURL: String {
        var u = url
        while u.hasSuffix("/") { u = String(u.dropLast()) }
        return u
    }

    var isValid: Bool {
        guard !name.isEmpty, !url.isEmpty, !anonKey.isEmpty else { return false }
        guard let parsed = URL(string: sanitizedURL),
              let scheme = parsed.scheme,
              ["http", "https"].contains(scheme.lowercased()),
              parsed.host != nil else { return false }
        return true
    }
}

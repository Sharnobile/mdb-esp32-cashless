import Foundation

/// Represents a company/organization in the VMflow system.
/// Maps to the `companies` table in Supabase.
struct Organization: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
    }
}

/// The response shape from the `get-my-organization` edge function.
struct OrganizationResponse: Codable {
    let organization: Organization?
    let role: String?
}

/// User role within an organization.
enum OrganizationRole: String, Codable {
    case admin
    case viewer
}

import Foundation

struct MembershipDTO: Codable, Equatable {
    let id: UUID
    let groupID: UUID
    let userID: UUID?
    let displayName: String
    let emoji: String
    let joinedAt: Date
    let createdAt: Date
    let updatedAt: Date
    let version: Int

    enum CodingKeys: String, CodingKey {
        case id
        case groupID = "group_id"
        case userID = "user_id"
        case displayName = "display_name"
        case emoji
        case joinedAt = "joined_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case version
    }
}

/// Body for PUT /memberships/:id.
struct MembershipUpsertDTO: Codable, Equatable {
    let id: UUID                       // iOS-provided; idempotent
    let groupID: UUID
    let displayName: String
    let emoji: String
    let updatedAt: Date?
    let version: Int
    /// Non-nil only when this membership is the authenticated user's own
    /// seat (host's "Me"). The server binds the membership's `user_id`
    /// **only** when this value equals `current_user.id`; any other value
    /// is treated as a ghost (`user_id: nil`). Replaces the previous
    /// `is_self: Bool` heuristic, which the server has stopped trusting
    /// (a host could forge it to bind any seat to themselves).
    let userID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case groupID = "group_id"
        case displayName = "display_name"
        case emoji
        case updatedAt = "updated_at"
        case version
        case userID = "user_id"
    }

    // Custom encoder lowercases `user_id` so its wire form matches
    // PostgreSQL's canonical UUID form on the backend. Swift's
    // `UUID.uuidString` is uppercase by default, and the backend's
    // owner-binding check is a strict string compare against
    // `current_user.id` (lowercase) — without this the host's own seat
    // lands as a ghost and the host then 403s their own group on the
    // next fetch. URL-path UUIDs are already lowercased in APIClient,
    // so the body field is the only stray uppercase value on the wire.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(groupID, forKey: .groupID)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(emoji, forKey: .emoji)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(userID?.uuidString.lowercased(), forKey: .userID)
    }
}

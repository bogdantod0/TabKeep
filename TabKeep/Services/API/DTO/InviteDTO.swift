import Foundation

struct InviteCreateResponse: Decodable {
    let token: String
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

struct InvitePreviewResponse: Decodable {
    struct Group: Decodable {
        let id: UUID
        let name: String
        let emoji: String?
        let memberCount: Int

        enum CodingKeys: String, CodingKey {
            case id, name, emoji
            case memberCount = "member_count"
        }
    }
    let group: Group
}

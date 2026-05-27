import Foundation

struct UserDTO: Codable, Equatable {
    let id: UUID
    let displayName: String
    let emoji: String
    let email: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case emoji
        case email
        case createdAt = "created_at"
    }
}

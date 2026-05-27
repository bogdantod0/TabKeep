import Foundation

struct DeviceInfoDTO: Codable, Equatable {
    let id: UUID
    let platform: String
    let createdAt: Date
    let lastSeenAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case platform
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

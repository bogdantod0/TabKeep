import Foundation

struct GroupDTO: Codable, Equatable {
    let id: UUID
    let ownerUserID: UUID
    let name: String
    let emoji: String?
    let currencyCode: String
    let archivedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let version: Int
    let memberships: [MembershipDTO]
    let expenses: [ExpenseDTO]
    let payments: [PaymentDTO]

    enum CodingKeys: String, CodingKey {
        case id
        case ownerUserID = "owner_user_id"
        case name
        case emoji
        case currencyCode = "currency_code"
        case archivedAt = "archived_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case version
        case memberships
        case expenses
        case payments
    }
}

/// Body for PUT /groups/:id (Phase 3 sync upsert).
struct GroupUpsertDTO: Codable, Equatable {
    let id: UUID
    let name: String
    let emoji: String?
    let currencyCode: String
    let archivedAt: Date?
    let version: Int

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, version
        case currencyCode = "currency_code"
        case archivedAt = "archived_at"
    }
}

import Foundation

struct PaymentDTO: Codable, Equatable {
    let id: UUID
    let groupID: UUID
    let fromMembershipID: UUID
    let toMembershipID: UUID
    let amount: DecimalString
    let occurredAt: Date
    let note: String?
    let expenseIDs: [UUID]?
    let deletedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let version: Int

    enum CodingKeys: String, CodingKey {
        case id
        case groupID = "group_id"
        case fromMembershipID = "from_membership_id"
        case toMembershipID = "to_membership_id"
        case amount
        case occurredAt = "occurred_at"
        case note
        case expenseIDs = "expense_ids"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case version
    }
}

struct PaymentUpsertDTO: Codable, Equatable {
    let id: UUID
    let groupID: UUID
    let fromMembershipID: UUID
    let toMembershipID: UUID
    let amount: DecimalString
    let occurredAt: Date
    let note: String?
    let expenseIDs: [UUID]?
    let updatedAt: Date?
    let version: Int

    enum CodingKeys: String, CodingKey {
        case id
        case groupID = "group_id"
        case fromMembershipID = "from_membership_id"
        case toMembershipID = "to_membership_id"
        case amount
        case occurredAt = "occurred_at"
        case note
        case expenseIDs = "expense_ids"
        case updatedAt = "updated_at"
        case version
    }
}

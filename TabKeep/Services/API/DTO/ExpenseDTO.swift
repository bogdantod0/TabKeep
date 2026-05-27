import Foundation

struct ExpenseShareDTO: Codable, Equatable {
    let membershipID: UUID
    let amount: DecimalString

    enum CodingKeys: String, CodingKey {
        case membershipID = "membership_id"
        case amount
    }
}

/// Per-member contribution row for a multi-payer expense. Mirrors
/// `ExpenseShareDTO` on the credit side. Server emits an empty array
/// when the expense uses the legacy single-payer model.
struct ExpensePaymentDTO: Codable, Equatable {
    let membershipID: UUID
    let amount: DecimalString

    enum CodingKeys: String, CodingKey {
        case membershipID = "membership_id"
        case amount
    }
}

struct ExpenseDTO: Codable, Equatable {
    let id: UUID
    let groupID: UUID
    let payerMembershipID: UUID
    let amount: DecimalString
    let currencyCode: String
    let exchangeRate: DecimalString
    let ratePending: Bool
    let description: String
    let category: String
    let occurredAt: Date
    let deletedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let version: Int
    let participantMembershipIDs: [UUID]
    let shares: [ExpenseShareDTO]
    let payments: [ExpensePaymentDTO]?
    let receipts: [ReceiptDTO]?

    enum CodingKeys: String, CodingKey {
        case id
        case groupID = "group_id"
        case payerMembershipID = "payer_membership_id"
        case amount
        case currencyCode = "currency_code"
        case exchangeRate = "exchange_rate"
        case ratePending = "rate_pending"
        case description
        case category
        case occurredAt = "occurred_at"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case version
        case participantMembershipIDs = "participant_membership_ids"
        case shares
        case payments
        case receipts
    }
}

struct ExpenseUpsertDTO: Codable, Equatable {
    let id: UUID
    let groupID: UUID
    let payerMembershipID: UUID
    let amount: DecimalString
    let currencyCode: String
    let exchangeRate: DecimalString
    let ratePending: Bool
    let description: String
    let category: String
    let occurredAt: Date
    let participantMembershipIDs: [UUID]?
    let shares: [ExpenseShareDTO]?
    let payments: [ExpensePaymentDTO]?
    let updatedAt: Date?
    let version: Int

    enum CodingKeys: String, CodingKey {
        case id
        case groupID = "group_id"
        case payerMembershipID = "payer_membership_id"
        case amount
        case currencyCode = "currency_code"
        case exchangeRate = "exchange_rate"
        case ratePending = "rate_pending"
        case description
        case category
        case occurredAt = "occurred_at"
        case participantMembershipIDs = "participant_membership_ids"
        case shares
        case payments
        case updatedAt = "updated_at"
        case version
    }
}

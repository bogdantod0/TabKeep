import Foundation

struct ActivityEntry: Codable, Hashable, Identifiable {
    let id: UUID
    let date: Date
    let groupID: UUID
    let kind: Kind
    /// Display name of the user who triggered this entry (host or guest).
    /// Set on edit entries so the activity feed can attribute changes —
    /// "Edited 'Hotel' by Alice". Optional + nil-default so older entries
    /// decode cleanly through the synthesized Codable (missing key → nil).
    let editorName: String?

    init(
        id: UUID,
        date: Date,
        groupID: UUID,
        kind: Kind,
        editorName: String? = nil
    ) {
        self.id = id
        self.date = date
        self.groupID = groupID
        self.kind = kind
        self.editorName = editorName
    }

    enum Kind: Codable, Hashable {
        case expenseEdited(expenseID: UUID, description: String, changes: [String])
        case expenseDeleted(expenseID: UUID, description: String, amount: Decimal, currencyCode: String, payerName: String)
        case paymentRecorded(paymentID: UUID, fromMemberName: String, toMemberName: String, amount: Decimal, currencyCode: String)
        case paymentEdited(paymentID: UUID, fromMemberName: String, toMemberName: String, changes: [String])
        case paymentDeleted(paymentID: UUID, fromMemberName: String, toMemberName: String, amount: Decimal, currencyCode: String)
        case draftRecorded(key: EntityKey)
    }
}

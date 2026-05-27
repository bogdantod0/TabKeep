import Foundation

struct ActivityEvent: Hashable, Identifiable {
    enum Kind: Hashable {
        case groupCreated
        case memberJoined(memberName: String)
        case expenseAdded(description: String, amount: Decimal, currencyCode: String, payerName: String)
        case paymentRecorded(fromMemberName: String, toMemberName: String, amount: Decimal, currencyCode: String)
    }

    let id: UUID
    let kind: Kind
    let groupID: UUID
    let groupName: String
    let date: Date
}

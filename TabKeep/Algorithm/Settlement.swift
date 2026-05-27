import Foundation

struct MemberBalance: Hashable {
    let memberID: UUID
    let netAmount: Decimal
}

struct Settlement: Hashable {
    let fromMemberID: UUID
    let toMemberID: UUID
    let amount: Decimal
}

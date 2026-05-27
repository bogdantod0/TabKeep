import Foundation

enum GroupsRoute: Hashable {
    case group(id: UUID)
    case expense(groupID: UUID, expenseID: UUID)
}

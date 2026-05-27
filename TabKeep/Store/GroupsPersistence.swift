import Foundation

struct PersistedState: Codable, Hashable {
    var groups: [ExpenseGroup]
    var defaultCurrencyCode: String
    var activityLog: [ActivityEntry] = []
    var pendingInviteToken: String? = nil
}

protocol GroupsPersistence {
    func load() throws -> PersistedState
    func save(_ state: PersistedState) throws
}

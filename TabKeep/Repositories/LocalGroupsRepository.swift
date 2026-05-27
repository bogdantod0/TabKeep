import Foundation

/// JSON-file-backed implementation. All remote-side methods throw
/// RepositoryError.unavailable — the Hybrid repository is responsible
/// for routing those calls to RemoteGroupsRepository instead.
actor LocalGroupsRepository: GroupsRepository {
    private let persistence: GroupsPersistence

    init(persistence: GroupsPersistence) {
        self.persistence = persistence
    }

    func loadAll() async throws -> PersistedState {
        try persistence.load()
    }

    func saveLocal(_ state: PersistedState) async throws {
        try persistence.save(state)
    }

    func listShared() async throws -> [ExpenseGroup] {
        throw RepositoryError.unavailable
    }

    func refresh(groupID: UUID) async throws -> ExpenseGroup {
        throw RepositoryError.unavailable
    }

    func putGroup(_ group: ExpenseGroup) async throws -> MutationOutcome<ExpenseGroup> {
        throw RepositoryError.unavailable
    }
    func putExpense(_ expense: Expense, in groupID: UUID) async throws -> MutationOutcome<Expense> {
        throw RepositoryError.unavailable
    }
    func putPayment(_ payment: Payment, in groupID: UUID) async throws -> MutationOutcome<Payment> {
        throw RepositoryError.unavailable
    }
    func putMember(_ member: Member, in groupID: UUID) async throws -> MutationOutcome<Member> {
        throw RepositoryError.unavailable
    }

    func deleteGroupVersioned(id: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void> {
        throw RepositoryError.unavailable
    }
    func deleteExpenseVersioned(id: UUID, in groupID: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void> {
        throw RepositoryError.unavailable
    }
    func deletePaymentVersioned(id: UUID, in groupID: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void> {
        throw RepositoryError.unavailable
    }
    func deleteMemberVersioned(id: UUID, in groupID: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void> {
        throw RepositoryError.unavailable
    }
}

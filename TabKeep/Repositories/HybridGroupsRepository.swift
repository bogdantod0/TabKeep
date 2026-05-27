import Foundation

/// Thin facade that routes GroupsRepository calls to the right backing
/// store: local-persistence methods go to LocalGroupsRepository; remote
/// reads and drainer PUT/DELETE methods go to RemoteGroupsRepository.
/// No per-group dispatch logic — every group syncs automatically when
/// signed-in via the SyncDrainer.
actor HybridGroupsRepository: GroupsRepository {
    private let local: LocalGroupsRepository
    private let remote: RemoteGroupsRepository

    init(local: LocalGroupsRepository, remote: RemoteGroupsRepository) {
        self.local = local
        self.remote = remote
    }

    // MARK: - GroupsRepository

    func loadAll() async throws -> PersistedState {
        try await local.loadAll()
    }

    func saveLocal(_ state: PersistedState) async throws {
        try await local.saveLocal(state)
    }

    func listShared() async throws -> [ExpenseGroup] {
        try await remote.listShared()
    }

    func refresh(groupID: UUID) async throws -> ExpenseGroup {
        try await remote.refresh(groupID: groupID)
    }

    func putGroup(_ group: ExpenseGroup) async throws -> MutationOutcome<ExpenseGroup> {
        try await remote.putGroup(group)
    }
    func putExpense(_ expense: Expense, in groupID: UUID) async throws -> MutationOutcome<Expense> {
        try await remote.putExpense(expense, in: groupID)
    }
    func putPayment(_ payment: Payment, in groupID: UUID) async throws -> MutationOutcome<Payment> {
        try await remote.putPayment(payment, in: groupID)
    }
    func putMember(_ member: Member, in groupID: UUID) async throws -> MutationOutcome<Member> {
        try await remote.putMember(member, in: groupID)
    }

    func deleteGroupVersioned(id: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void> {
        try await remote.deleteGroupVersioned(id: id, ifMatchVersion: ifMatchVersion)
    }
    func deleteExpenseVersioned(id: UUID, in groupID: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void> {
        try await remote.deleteExpenseVersioned(id: id, in: groupID, ifMatchVersion: ifMatchVersion)
    }
    func deletePaymentVersioned(id: UUID, in groupID: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void> {
        try await remote.deletePaymentVersioned(id: id, in: groupID, ifMatchVersion: ifMatchVersion)
    }
    func deleteMemberVersioned(id: UUID, in groupID: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void> {
        try await remote.deleteMemberVersioned(id: id, in: groupID, ifMatchVersion: ifMatchVersion)
    }
}

import Foundation

/// Outcome of a server-side mutation. Per-resource generic so the caller
/// always knows the exact entity type returned.
enum MutationOutcome<T> {
    case applied(T)        // 2xx — server agrees
    case staleWrite(T)     // 409 — server's current state, banner shown by AppStore
}

enum RepositoryError: Error, Equatable {
    case unavailable       // method not supported by this repository impl
    case notSignedIn       // remote method called without a bearer token
}

/// The single persistence + sync surface that AppStore talks to.
/// Two impls: LocalGroupsRepository (JSON) and HybridGroupsRepository
/// (delegates local to Local, remote to RemoteGroupsRepository).
protocol GroupsRepository: Sendable {
    // Bootstrap
    func loadAll() async throws -> PersistedState

    // Local-only lifecycle
    func saveLocal(_ state: PersistedState) async throws

    // Server reads
    func listShared() async throws -> [ExpenseGroup]
    func refresh(groupID: UUID) async throws -> ExpenseGroup

    // Per-entity sync (drainer-only callers)
    func putGroup(_ group: ExpenseGroup) async throws -> MutationOutcome<ExpenseGroup>
    func putExpense(_ expense: Expense, in groupID: UUID) async throws -> MutationOutcome<Expense>
    func putPayment(_ payment: Payment, in groupID: UUID) async throws -> MutationOutcome<Payment>
    func putMember(_ member: Member, in groupID: UUID) async throws -> MutationOutcome<Member>

    func deleteGroupVersioned(id: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void>
    func deleteExpenseVersioned(id: UUID, in groupID: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void>
    func deletePaymentVersioned(id: UUID, in groupID: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void>
    func deleteMemberVersioned(id: UUID, in groupID: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void>
}

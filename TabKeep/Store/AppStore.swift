import Foundation
import Observation
import os

enum AppStoreError: Error, Equatable {
    case groupNotFound
    case memberNotInGroup
    /// Caller tried to remove a member who's still referenced by expenses
    /// or payments. The associated counts let the UI explain exactly what's
    /// blocking removal ("Alice is in 3 expenses and 1 payment…").
    case memberHasExpenses(expenseCount: Int, paymentCount: Int)
    case expenseNotFound
    case unsupportedCurrency
    case splitAmountMismatch
    case invalidExpense
    case invalidPayment
    case paymentNotFound
    case groupArchived
    case forbidden
    /// Caller tried to change a group's currencyCode while the group still
    /// has recorded payments. Payments are stored as raw `Decimal` in the
    /// group's currency (no per-payment rate snapshot), so a currency change
    /// would silently re-interpret existing amounts. Refuse until payments
    /// are deleted or model evolves to carry per-payment currency.
    case groupHasPayments
}

struct ConflictBanner: Identifiable, Equatable {
    enum Kind: Equatable {
        case expense(groupID: UUID, expenseID: UUID)
        case payment(groupID: UUID, paymentID: UUID)
        case member(groupID: UUID, memberID: UUID)
        case group(groupID: UUID)
        case groupDeleted(groupID: UUID, name: String)
        /// The host removed the current user's seat from the group, so the
        /// group disappears from this device. Distinct from `groupDeleted`,
        /// which fires when the host deletes the group entirely.
        case removedFromGroup(groupID: UUID, name: String)
        /// Server returned 403 on a mutation — the current user isn't
        /// allowed to perform `action` on the entity identified by
        /// `entityLabel` (e.g. "expense"). AppStore auto-refreshes the
        /// group so the local UI matches server state.
        case permissionDenied(groupID: UUID, entityLabel: String, action: PermissionDeniedAction)
        /// Server rejected the receipt upload — too large or unsupported
        /// content type. Local row stays so the user can still view the photo.
        case receiptTooLarge(groupID: UUID, expenseID: UUID?)
    }
    let id: UUID = UUID()
    let kind: Kind
    let createdAt: Date = Date()

    var message: String {
        switch kind {
        case .expense:           return "This expense was updated by someone else — your changes weren't saved."
        case .payment:           return "This payment was updated by someone else."
        case .member:            return "This member was updated elsewhere."
        case .group:             return "This group was updated by someone else."
        case .groupDeleted:      return "This group was removed by the host."
        case .removedFromGroup:  return "You were removed from this group."
        case .permissionDenied(_, let label, let action):
            switch action {
            case .delete: return "You don't have permission to delete this \(label)."
            case .upsert: return "You don't have permission to edit this \(label)."
            }
        case .receiptTooLarge:
            return "Receipt was too large to upload."
        }
    }
}

struct PendingDeletion: Identifiable, Hashable {
    enum Kind: Hashable {
        case expense(Expense, originalIndex: Int)
        /// Payment deletions snapshot the group's currencyCode at start
        /// time so commit doesn't depend on the group still existing
        /// (rare race) for the activity-log entry's currency.
        case payment(Payment, originalIndex: Int, currencyCode: String)
    }

    let id: UUID
    let groupID: UUID
    let groupName: String
    let kind: Kind
    let startedAt: Date
}

struct PendingBackfill: Identifiable, Hashable {
    let id: UUID
    let groupID: UUID
    let memberID: UUID
    let expenseIDs: [UUID]
    let skippedCustomShareCount: Int
    let skippedSettledCount: Int
}

/// Captured invite-preview info that drives the warm-tap confirm sheet.
/// Set by AppStore.handleIncomingInvite (warm path), observed by RootTabView.
struct PendingInviteConfirm: Identifiable, Hashable {
    let id = UUID()
    let rawToken: String
    let groupID: UUID
    let groupName: String
    let groupEmoji: String?
    let memberCount: Int
}

/// 5-second auto-dismissed banner shown when an invite link is invalid
/// (revoked, expired, not-found) or transport failed. Observed by overlays.
struct InviteErrorBanner: Identifiable, Hashable {
    let id = UUID()
    let message: String
}

private enum InviteErrorCode {
    static let revoked = "invite_revoked"
    static let expired = "invite_expired"
    static let notFound = "not_found"
}

@Observable
final class AppStore {
    private(set) var groups: [ExpenseGroup] = []
    private(set) var activityLog: [ActivityEntry] = []
    private(set) var pendingDeletion: PendingDeletion?
    private(set) var pendingBackfill: PendingBackfill?
    private(set) var isRetryingPendingRates: Bool = false

    private(set) var conflictBanners: [ConflictBanner] = []
    private(set) var drafts: [EntityKey: RejectedDraft] = [:]
    var activeEditingEntity: (groupID: UUID, entityID: UUID)? = nil
    var upgradeRequiredMinimum: String? = nil

    /// Token captured from a deferred deep link before sign-in / onboarding
    /// completed. Persisted via PersistedState so a kill-and-relaunch during
    /// onboarding doesn't lose it. Cleared after a successful accept (or when
    /// preview returns invite_revoked/invite_expired/not_found).
    var pendingInviteToken: String?
    /// Drives the warm-tap confirm sheet (RootTabView, Task 12).
    var pendingInviteConfirm: PendingInviteConfirm?
    /// Drives a 5s "invite link no longer valid" banner overlay (Task 12).
    var inviteErrorBanner: InviteErrorBanner?
    /// Set after a successful accept; observed by RootTabView (Task 12) to
    /// navigate to the joined group and show a toast. Consumer clears it.
    var lastJoinedGroupID: UUID?

    /// Re-entrancy guard for `handleIncomingInvite`. Cold-path (RootTabView
    /// `.task` consuming `pendingInviteToken`) and warm-path (`onOpenURL`)
    /// can fire near-simultaneously when a fresh tap lands while a prior
    /// deferred token is still being processed. The flag drops the second
    /// caller so the two paths don't interleave their state writes.
    private var inviteProcessingActive = false

    /// Device-owner identity, persisted to UserDefaults. Not part of
    /// PersistedState because it's per-device, not per-ledger.
    var user: User {
        didSet { Self.persist(user: user) }
    }
    private let repository: GroupsRepository
    let syncState: SyncState
    let syncDrainer: SyncDrainer
    private let simplifier: DebtSimplifier
    private let fxService: FXService
    private let isSignedInProvider: @Sendable () -> Bool
    /// Mints / previews / accepts invites. Optional so test factories and
    /// in-memory previews can omit it; nil disables all invite methods.
    private let inviteService: InviteService?
    /// Registers an anonymous device so the host has a server-known identity
    /// before minting an invite (or accepting one). Wired by TabKeepApp at
    /// Task 13 to AuthSession.registerAnonymousDevice. Optional for tests.
    private let anonRegister: (@Sendable () async throws -> Void)?
    /// Fire-and-forget push permission prompt. Called from
    /// `finishAcceptingInvite` so a fresh install that arrived via an
    /// invite link gets the system prompt right after a successful join,
    /// in case the `.onChange(of: hasOnboarded)` path raced or the user
    /// somehow reached the accept flow before completing onboarding.
    /// Wired by TabKeepApp to `PushService.requestAuthorizationAndRegister`.
    /// Optional for tests.
    private let requestPushPermission: (@Sendable () async -> Void)?
    /// Pushes the current local profile to the server (PATCH /me). Wired
    /// at App init via AuthSession.updateProfile. Returns the canonicalized
    /// server response, or nil if the call failed (we keep local in that
    /// case; next foreground refresh re-syncs).
    var profileSyncer: (@Sendable (String, String) async -> UserDTO?)?
    private(set) var defaultCurrencyCode: String = "USD"

    /// User-selected app appearance. Persisted to UserDefaults at the
    /// `appearanceKey` key. Read at init via `Self.loadAppearance()`,
    /// written by `setAppearance(_:)`.
    private(set) var appearance: AppearancePreference = .system

    private let persistErrorLog = Logger(subsystem: "com.example.tabkeep", category: "appstore")

    /// Per-group completion timestamps + in-flight Task handles used to
    /// throttle and coalesce `refresh(groupID:)`. Navigation hooks call
    /// the wrapper freely; the wrapper decides whether to actually hit
    /// the network. User gestures (pull-to-refresh) and just-happened
    /// events (notification tap, cold launch) pass `force: true` to
    /// bypass the throttle. Marked @ObservationIgnored so dict writes
    /// don't invalidate every observing view.
    @ObservationIgnored
    private var lastRefreshAt: [UUID: Date] = [:]
    @ObservationIgnored
    private var inFlightRefresh: [UUID: Task<Void, Never>] = [:]
    private static let refreshThrottleInterval: TimeInterval = 10

    /// Per-group timestamps of recently-completed invite accepts. Concurrent
    /// GETs (foregroundRefresh, GroupDetailView's onAppear refresh) can race
    /// the server's membership-creation transaction and return a stale group
    /// without our seat — `evictGroupRemovedByHost` would then re-post the
    /// "you were removed" banner moments after the join. The grace window
    /// here suppresses eviction for a few seconds after each accept so the
    /// stale-GET race resolves on its own.
    @ObservationIgnored
    private var recentInviteAccepts: [UUID: Date] = [:]
    private static let inviteAcceptGracePeriod: TimeInterval = 5

    init(
        repository: GroupsRepository,
        syncState: SyncState,
        syncDrainer: SyncDrainer,
        simplifier: DebtSimplifier = GreedyDebtSimplifier(),
        fxService: FXService = FrankfurterFXService(),
        isSignedIn: @escaping @Sendable () -> Bool = { false },
        inviteService: InviteService? = nil,
        anonRegister: (@Sendable () async throws -> Void)? = nil,
        requestPushPermission: (@Sendable () async -> Void)? = nil
    ) {
        self.repository = repository
        self.syncState = syncState
        self.syncDrainer = syncDrainer
        self.simplifier = simplifier
        self.fxService = fxService
        self.isSignedInProvider = isSignedIn
        self.inviteService = inviteService
        self.anonRegister = anonRegister
        self.requestPushPermission = requestPushPermission
        self.user = Self.loadUser()
        self.appearance = Self.loadAppearance()
        Task { await self.loadInitial() }
    }

    @MainActor
    func lookup(entityKey k: EntityKey) -> Any? {
        switch k.kind {
        case .group:
            return groups.first(where: { $0.id == k.id })
        case .expense:
            return groups.first(where: { $0.id == k.groupID })?.expenses.first(where: { $0.id == k.id })
        case .payment:
            return groups.first(where: { $0.id == k.groupID })?.payments?.first(where: { $0.id == k.id })
        case .member:
            return groups.first(where: { $0.id == k.groupID })?.members.first(where: { $0.id == k.id })
        case .receipt:
            guard let group = groups.first(where: { $0.id == k.groupID }) else { return nil }
            for expense in group.expenses {
                if let receipt = expense.receipts.first(where: { $0.id == k.id }) {
                    return ReceiptDrainLocal(receipt: receipt, expenseID: expense.id)
                }
            }
            return nil
        }
    }

    @MainActor
    func apply(serverEvent event: ServerEvent) {
        switch event {
        case .upserted(let k, let payload):
            // Don't clobber a still-dirty entity (re-edited during drain).
            Task { [weak self] in
                guard let self else { return }
                let stillDirty = await self.syncState.isDirty(k)
                if stillDirty { return }
                await MainActor.run { self.applyUpsertedPayload(k, payload: payload) }
            }
        case .deleted(let k):
            applyDelete(k)
        case .conflict(let k, let server, _):
            applyConflict(k, server: server)
        case .groupGoneOnServer(let id):
            applyGroupGone(id)
        case .permissionDenied(let k, let action):
            applyPermissionDenied(k, action: action)
        case .receiptRejected(let k, let reason):
            // Hard validation failure (too large, unsupported type). Local row
            // stays in the model so the user can still view the photo; banner
            // dismisses via the existing ConflictBanner UI.
            _ = reason   // logged via console; not surfaced in banner message yet
            conflictBanners.append(ConflictBanner(kind: .receiptTooLarge(groupID: k.groupID, expenseID: nil)))
        case .receiptFileMissing(let k):
            // Drainer found the local JPEG gone before it could PUT. The receipt
            // row is dangling — remove from the model so it stops rendering.
            removeReceiptFromModel(receiptID: k.id, in: k.groupID)
        }
    }

    /// Adopts server-canonical metadata onto the local copy of a group.
    /// Used by both server-event ingestion (applyUpsertedPayload) and the
    /// stale-write recovery path in createInvite. Centralizing the field
    /// list prevents drift if a new server-canonical field is added.
    @MainActor
    private func adoptServerGroupMetadata(_ server: ExpenseGroup) {
        guard let i = groups.firstIndex(where: { $0.id == server.id }) else { return }
        groups[i].version = server.version
        groups[i].updatedAt = server.updatedAt
        groups[i].name = server.name
        groups[i].emoji = server.emoji
        groups[i].currencyCode = server.currencyCode
        groups[i].archivedAt = server.archivedAt
    }

    @MainActor
    private func applyUpsertedPayload(_ k: EntityKey, payload: Any) {
        guard let groupIdx = groups.firstIndex(where: { $0.id == k.groupID }) else { return }
        switch k.kind {
        case .group:
            if let server = payload as? ExpenseGroup {
                adoptServerGroupMetadata(server)
            }
        case .expense:
            if var server = payload as? Expense,
               let i = groups[groupIdx].expenses.firstIndex(where: { $0.id == server.id }) {
                // splitKind is local-only metadata (server doesn't persist
                // it). The server response always has splitKind == nil, so
                // we restore the local value before replacing.
                server.splitKind = groups[groupIdx].expenses[i].splitKind
                // Receipts upsert via a separate POST /expenses/:id/receipts
                // sequence; their wire envelope is filtered to
                // `expense.receipts.live.ready`. A receipt that's still
                // mid-finalize when the parent expense PUT returns is
                // therefore ABSENT from server.receipts. Union local
                // receipts the server doesn't know about yet onto server's
                // list so a freshly-added receipt isn't blown away —
                // applies on initial add (server returns []) and on edit
                // where some receipts are already finalized and others
                // are still in flight.
                let serverReceiptIDs = Set(server.receipts.map(\.id))
                let inFlight = groups[groupIdx].expenses[i].receipts.filter {
                    !serverReceiptIDs.contains($0.id)
                }
                if !inFlight.isEmpty {
                    server.receipts.append(contentsOf: inFlight)
                }
                groups[groupIdx].expenses[i] = server
            }
        case .payment:
            if let server = payload as? Payment,
               var pays = groups[groupIdx].payments,
               let i = pays.firstIndex(where: { $0.id == server.id }) {
                pays[i] = server
                groups[groupIdx].payments = pays
            }
        case .member:
            if var server = payload as? Member,
               let i = groups[groupIdx].members.firstIndex(where: { $0.id == server.id }) {
                // archivedAt is local-only metadata. The server doesn't store
                // it, so we restore the local value before replacing.
                server.archivedAt = groups[groupIdx].members[i].archivedAt
                groups[groupIdx].members[i] = server
            }
        case .receipt:
            // T6 emits this with the local receipt as payload after a successful
            // finalize. We have nothing server-canonical to adopt — the server
            // doesn't return the receipt row from finalize (it's 204). On the
            // next group refresh the receipt envelope will include
            // uploader_user_id, which patches the local row through the regular
            // remote-repository parse path.
            break
        }
        Task { await persist() }
    }

    @MainActor
    private func applyDelete(_ k: EntityKey) {
        guard let groupIdx = groups.firstIndex(where: { $0.id == k.groupID }) else { return }
        switch k.kind {
        case .group:
            groups.remove(at: groupIdx)
        case .expense:
            groups[groupIdx].expenses.removeAll { $0.id == k.id }
        case .payment:
            if var pays = groups[groupIdx].payments {
                pays.removeAll { $0.id == k.id }
                groups[groupIdx].payments = pays
            }
        case .member:
            groups[groupIdx].members.removeAll { $0.id == k.id }
        case .receipt:
            // Drainer just confirmed the server-side soft-delete. The model row
            // is typically already gone (editExpense removes it) but we sweep
            // defensively to clean up any stragglers, and to drop the on-disk
            // JPEG (deferred from editExpense so the drainer could still read
            // bytes if a pushReceipt was in flight).
            removeReceiptFromModel(receiptID: k.id, in: k.groupID)
            return    // helper already persists; skip the trailing Task { await persist() }
        }
        Task { await persist() }
    }

    @MainActor
    private func removeReceiptFromModel(receiptID: UUID, in groupID: UUID) {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var changed = false
        for ei in groups[gi].expenses.indices {
            let before = groups[gi].expenses[ei].receipts.count
            groups[gi].expenses[ei].receipts.removeAll { $0.id == receiptID }
            if groups[gi].expenses[ei].receipts.count != before { changed = true }
        }
        if changed {
            ReceiptStore.default().delete(id: receiptID)
            Task { await persist() }
        }
    }

    static func entityKey(for kind: ConflictBanner.Kind) -> EntityKey? {
        switch kind {
        case .expense(let g, let id):  return .expense(id, in: g)
        case .payment(let g, let id):  return .payment(id, in: g)
        case .member(let g, let id):   return .member(id, in: g)
        case .group(let g):            return .group(g)
        case .groupDeleted:            return nil
        case .removedFromGroup:        return nil
        // Permission-denied banners carry no draft — the user can't retry
        // by reviewing or re-saving, so ConflictBannerRow renders a plain
        // "Dismiss" affordance.
        case .permissionDenied:        return nil
        case .receiptTooLarge:
            // Informational banner — no draft to navigate to, so the
            // ConflictBannerStack lets the auto-dismiss timer fire after 5s.
            return nil
        }
    }

    @MainActor
    private func applyConflict(_ k: EntityKey, server: Any?) {
        if let server { applyUpsertedPayload(k, payload: server) }
        let kind: ConflictBanner.Kind
        switch k.kind {
        case .group:   kind = .group(groupID: k.groupID)
        case .expense: kind = .expense(groupID: k.groupID, expenseID: k.id)
        case .payment: kind = .payment(groupID: k.groupID, paymentID: k.id)
        case .member:  kind = .member(groupID: k.groupID, memberID: k.id)
        case .receipt:
            // Receipts don't surface conflict banners — the drainer's no-op
            // arms clear them immediately. This path is unreachable in T5.
            return
        }
        conflictBanners.append(ConflictBanner(kind: kind))

        activityLog.append(ActivityEntry(
            id: UUID(),
            date: Date(),
            groupID: k.groupID,
            kind: .draftRecorded(key: k)
        ))
        Task { await persist() }

        // Mirror the draft (set by the drainer in SyncState moments ago).
        Task { [weak self] in
            guard let self else { return }
            if let draft = await self.syncState.draft(for: k) {
                await MainActor.run { self.drafts[k] = draft }
            }
        }
    }

    /// Server rejected the mutation with 403. The drainer has already
    /// cleared the dirty / tombstone for this key, so the local entity is
    /// out of sync with the server (a delete attempt removed it locally
    /// but it still exists upstream; an edit attempt rewrote local fields
    /// the server won't accept). A forced refresh of the parent group
    /// pulls server-canonical state and naturally resurrects the entity
    /// (delete case) or reverts the fields (edit case).
    @MainActor
    private func applyPermissionDenied(_ k: EntityKey, action: PermissionDeniedAction) {
        Task { await self.refresh(groupID: k.groupID, force: true) }
        conflictBanners.append(
            ConflictBanner(kind: .permissionDenied(
                groupID: k.groupID,
                entityLabel: Self.entityLabel(for: k.kind),
                action: action
            ))
        )
        Task { await persist() }
    }

    private static func entityLabel(for kind: EntityKind) -> String {
        switch kind {
        case .group:   return "group"
        case .expense: return "expense"
        case .payment: return "payment"
        case .member:  return "member"
        case .receipt: return "receipt"
        }
    }

    @MainActor
    func discardDraft(_ k: EntityKey) {
        drafts.removeValue(forKey: k)
        conflictBanners.removeAll { Self.entityKey(for: $0.kind) == k }
        Task { await syncState.discardDraft(k) }
    }

    @MainActor
    func confirmDeleteFromDraft(_ k: EntityKey) {
        guard let d = drafts[k], case .tombstone = d.kind else { return }
        drafts.removeValue(forKey: k)
        conflictBanners.removeAll { Self.entityKey(for: $0.kind) == k }
        let v = d.serverVersionAtReject
        Task {
            await syncState.markTombstone(k, lastKnownVersion: v)
            await syncState.discardDraft(k)
            await syncDrainer.kick()
        }
    }

    /// Set by `openDraftReview`; observed by `RootTabView` to navigate the
    /// groups stack to the entity. Reset to `nil` after consumption.
    var pendingNavigation: GroupsRoute? = nil

    @MainActor
    func openDraftReview(_ k: EntityKey) {
        conflictBanners.removeAll { Self.entityKey(for: $0.kind) == k }
        switch k.kind {
        case .expense:
            pendingNavigation = .expense(groupID: k.groupID, expenseID: k.id)
        case .group:
            pendingNavigation = .group(id: k.id)
        case .payment, .member, .receipt:
            // Routing for these isn't wired in GroupsRoute yet; navigate to
            // the parent group so the user can find the row.
            pendingNavigation = .group(id: k.groupID)
        }
    }

    @MainActor
    func consumePendingNavigation() -> GroupsRoute? {
        let r = pendingNavigation
        pendingNavigation = nil
        return r
    }

    @MainActor
    private func applyGroupGone(_ id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let name = groups[i].name
        groups.remove(at: i)
        conflictBanners.append(ConflictBanner(kind: .groupDeleted(groupID: id, name: name)))
        Task { await persist() }
    }

    private func loadInitial() async {
        do {
            let state = try await repository.loadAll()
            self.groups = state.groups
            self.activityLog = state.activityLog
            self.defaultCurrencyCode = state.defaultCurrencyCode.isEmpty ? "USD" : state.defaultCurrencyCode
            self.pendingInviteToken = state.pendingInviteToken

            // Self-heal data from earlier soft-archive builds: any member
            // currently archived but still referenced by an expense or
            // payment gets un-archived. Going forward `removeMember`
            // refuses to archive a referenced member, so this sweep only
            // matters for stores written before that guard landed.
            if repairArchivedReferencedMembers() {
                await persist()
            }

            // Migration for the pre-tombstone removeMember: members
            // archived by an earlier build never got a server-delete
            // queued, so a refresh would resurrect them. Tombstone each
            // surviving archive so the drainer finishes the job. Solo
            // (never-pushed) groups will 404 and clear cleanly.
            await tombstoneOrphanedArchivedMembers()

            // Backstop for the persist/markDirty race: ensure every
            // version-0 entity has a corresponding sync-state entry.
            await reconcileUnsyncedEntities()
        } catch {
            self.groups = []
            self.activityLog = []
            self.defaultCurrencyCode = "USD"
            self.pendingInviteToken = nil
        }
    }

    /// Queues a server-delete for any archived member that doesn't
    /// already have one pending. Idempotent — re-running on a clean
    /// store is a no-op because tombstoned members are dropped from
    /// local state by the drainer's `applyDelete`.
    private func tombstoneOrphanedArchivedMembers() async {
        for group in groups {
            for member in group.members where member.archivedAt != nil {
                let key = EntityKey.member(member.id, in: group.id)
                if await syncState.isTombstone(key) { continue }
                await syncState.markTombstone(key, lastKnownVersion: member.version)
            }
        }
    }

    /// Backstop for the persist/markDirty race: any locally-stored
    /// entity with `version == 0` has never been confirmed by the
    /// server, so it must be either dirty (waiting to upsert),
    /// tombstoned (waiting to delete), or a rejected draft (user
    /// must resolve). If a version-0 entity has none of those, it
    /// was orphaned by a crash between `persist()` and
    /// `markDirty(...)`; mark it dirty here so the next drain
    /// catches it up.
    ///
    /// Idempotent — re-running on a fully-synced store is a no-op.
    /// Safe to call after `loadInitial` finishes restoring both
    /// `groups` and the `syncState` actor's contents.
    private func reconcileUnsyncedEntities() async {
        for group in groups {
            let groupKey = EntityKey.group(group.id)
            if group.version == 0 {
                let dirty = await syncState.isDirty(groupKey)
                let tomb  = await syncState.isTombstone(groupKey)
                let draft = await syncState.draft(for: groupKey)
                if !dirty && !tomb && draft == nil {
                    await syncState.markDirty(groupKey)
                }
            }

            for member in group.members {
                let key = EntityKey.member(member.id, in: group.id)
                if member.version == 0 && member.archivedAt == nil {
                    let dirty = await syncState.isDirty(key)
                    let tomb  = await syncState.isTombstone(key)
                    let draft = await syncState.draft(for: key)
                    if !dirty && !tomb && draft == nil {
                        await syncState.markDirty(key)
                    }
                }
            }

            for expense in group.expenses {
                let key = EntityKey.expense(expense.id, in: group.id)
                if expense.version == 0 {
                    let dirty = await syncState.isDirty(key)
                    let tomb  = await syncState.isTombstone(key)
                    let draft = await syncState.draft(for: key)
                    if !dirty && !tomb && draft == nil {
                        await syncState.markDirty(key)
                    }
                }
            }

            for payment in (group.payments ?? []) {
                let key = EntityKey.payment(payment.id, in: group.id)
                if payment.version == 0 {
                    let dirty = await syncState.isDirty(key)
                    let tomb  = await syncState.isTombstone(key)
                    let draft = await syncState.draft(for: key)
                    if !dirty && !tomb && draft == nil {
                        await syncState.markDirty(key)
                    }
                }
            }
        }
    }

    /// Un-archives any archived member who is still referenced by an
    /// expense or payment in their group. Returns `true` when at least
    /// one member was un-archived (so the caller knows to persist).
    @discardableResult
    private func repairArchivedReferencedMembers() -> Bool {
        var changed = false
        for gIdx in groups.indices {
            for mIdx in groups[gIdx].members.indices
            where groups[gIdx].members[mIdx].archivedAt != nil {
                let memberID = groups[gIdx].members[mIdx].id
                let inExpenses = groups[gIdx].expenses.contains {
                    $0.payerID == memberID || $0.participantIDs.contains(memberID)
                }
                let inPayments = (groups[gIdx].payments ?? []).contains {
                    $0.fromMemberID == memberID || $0.toMemberID == memberID
                }
                if inExpenses || inPayments {
                    groups[gIdx].members[mIdx].archivedAt = nil
                    changed = true
                }
            }
        }
        return changed
    }

    // MARK: - User identity

    private static let userNameKey = "userName"
    private static let userEmojiKey = "userEmoji"
    private static let userServerIDKey = "userServerID"

    private static func loadUser() -> User {
        let defaults = UserDefaults.standard
        let name = defaults.string(forKey: userNameKey) ?? ""
        let emoji = defaults.string(forKey: userEmojiKey) ?? User.defaultEmoji
        let serverID = (defaults.string(forKey: userServerIDKey)).flatMap(UUID.init(uuidString:))
        return User(name: name, emoji: emoji, serverID: serverID)
    }

    private static func persist(user: User) {
        let defaults = UserDefaults.standard
        defaults.set(user.name, forKey: userNameKey)
        defaults.set(user.emoji, forKey: userEmojiKey)
        if let id = user.serverID {
            defaults.set(id.uuidString, forKey: userServerIDKey)
        } else {
            defaults.removeObject(forKey: userServerIDKey)
        }
    }

    // MARK: - Appearance preference

    static let appearanceKey = "appearance"

    private static func loadAppearance() -> AppearancePreference {
        guard let raw = UserDefaults.standard.string(forKey: appearanceKey),
              let pref = AppearancePreference(rawValue: raw) else {
            return .system
        }
        return pref
    }

    /// Updates the device-wide appearance preference and persists it
    /// synchronously to `UserDefaults`. Views observing `AppStore` will
    /// re-render automatically; `TabKeepApp` re-evaluates
    /// `.preferredColorScheme(...)` on the root.
    func setAppearance(_ pref: AppearancePreference) {
        guard pref != appearance else { return }
        appearance = pref
        UserDefaults.standard.set(pref.rawValue, forKey: Self.appearanceKey)
    }

    /// Clears the user's name and avatar both in memory and on disk.
    /// Used by Reset All Data and the Restart Onboarding debug action.
    func clearUser() {
        user = User.empty
    }

    @MainActor
    func setUpgradeRequired(_ minimum: String) {
        self.upgradeRequiredMinimum = minimum
    }

    // MARK: - User profile sync

    /// Adopt the server's canonical profile into local state. Called from
    /// AuthSession (sign-in / bootstrap / refresh / link / profile PATCH).
    /// If the local profile has been customized while the server's is
    /// still empty (= first sign-in for this user), push local up first
    /// instead of letting the server's blank values clobber the user's
    /// onboarding entry.
    @MainActor
    func applyServerProfile(_ dto: UserDTO) async {
        let serverEmpty = dto.displayName.trimmingCharacters(in: .whitespaces).isEmpty
        let oldMatchKey = user.matchKey
        if serverEmpty && user.hasName {
            // Push local up. Server adopts; we'll mirror its canonicalized
            // response below (or keep local if PATCH fails).
            if let push = profileSyncer,
               let pushed = await push(user.name, user.emoji) {
                user = User(name: pushed.displayName, emoji: pushed.emoji, serverID: pushed.id)
            } else {
                // Push failed; at least record serverID so member identity works.
                if user.serverID != dto.id { user.serverID = dto.id }
            }
            return
        }
        // Otherwise: server is canonical, mirror it locally. Preserve the
        // local emoji as a fallback when the server returns empty (older
        // accounts) so the UI doesn't flash to the default glyph.
        let resolvedEmoji = dto.emoji.isEmpty ? user.emoji : dto.emoji
        let resolvedName = serverEmpty ? user.name : dto.displayName
        let next = User(name: resolvedName, emoji: resolvedEmoji, serverID: dto.id)
        if next != user { user = next }
        // CRITICAL: cascade the rename into local memberships. Otherwise
        // the user's "Me" member in anonymous-era groups still carries the
        // old name; the drainer's `is_self` detection (name-match against
        // user.matchKey) fails, the server stores the membership as a
        // ghost, and the expense PUT 403s because `current_user` has no
        // matching membership in the group.
        let nameChanged = user.matchKey != oldMatchKey
        let emojiChanged = next.emoji != resolvedEmoji   // unused (kept for clarity)
        _ = emojiChanged
        if nameChanged {
            cascadeProfileToMemberships(
                newName: resolvedName, newEmoji: resolvedEmoji,
                oldMatchKey: oldMatchKey, markDirty: isSignedInProvider()
            )
        }
    }

    /// Settings entry-point. Updates local immediately for snappy UI, then
    /// (if signed-in) PATCHes the server. On success, mirrors any server
    /// canonicalization (e.g., trimming) back into local. On failure keeps
    /// local; the next /me refresh will reconcile.
    @MainActor
    func setProfile(name: String, emoji: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let oldMatchKey = user.matchKey
        let local = User(name: trimmed, emoji: emoji, serverID: user.serverID)
        if local != user { user = local }
        let signedIn = isSignedInProvider()
        if !signedIn {
            // Anonymous: cascade locally only (no server PATCH, no drainer
            // dirty-mark — drainer is a no-op while signed-out anyway, but
            // we don't want pending dirty entries piling up either).
            cascadeProfileToMemberships(
                newName: trimmed, newEmoji: emoji,
                oldMatchKey: oldMatchKey, markDirty: false
            )
            return
        }
        guard let push = profileSyncer else { return }
        if let pushed = await push(trimmed, emoji) {
            let canonical = User(name: pushed.displayName, emoji: pushed.emoji, serverID: pushed.id)
            if canonical != user { user = canonical }
            // Cascade and mark each updated member dirty so the drainer
            // PUTs the rename server-side; other devices pick up the new
            // name on their next foreground refresh.
            cascadeProfileToMemberships(
                newName: pushed.displayName, newEmoji: pushed.emoji,
                oldMatchKey: oldMatchKey, markDirty: true
            )
        }
    }

    /// Update the user's "Me" member in every group to match the new
    /// profile. Identifies the member two ways:
    ///   1. `member.userID == user.serverID` — definitive match for
    ///      memberships the server has stamped via `is_self: true`.
    ///   2. Fallback: name match against the user's previous name
    ///      (`oldMatchKey`). Catches anonymous-era memberships and groups
    ///      created before sign-in whose `userID` isn't populated yet.
    /// When `markDirty` is true, queues each updated member for sync.
    @MainActor
    private func cascadeProfileToMemberships(
        newName: String,
        newEmoji: String,
        oldMatchKey: String,
        markDirty: Bool
    ) {
        var dirtied: [(groupID: UUID, memberID: UUID)] = []
        let serverID = user.serverID
        for gIdx in groups.indices {
            let i: Int? = {
                if let serverID,
                   let idIdx = groups[gIdx].members.firstIndex(where: { $0.userID == serverID }) {
                    return idIdx
                }
                guard !oldMatchKey.isEmpty else { return nil }
                return groups[gIdx].members.firstIndex {
                    $0.name.trimmingCharacters(in: .whitespaces).lowercased() == oldMatchKey
                }
            }()
            guard let memberIdx = i else { continue }
            var member = groups[gIdx].members[memberIdx]
            if member.name == newName && member.emoji == newEmoji { continue }
            member.name = newName
            member.emoji = newEmoji
            groups[gIdx].members[memberIdx] = member
            dirtied.append((groups[gIdx].id, member.id))
        }
        if dirtied.isEmpty { return }
        Task { [dirtied, markDirty] in
            if markDirty {
                for d in dirtied {
                    await syncState.markDirty(.member(d.memberID, in: d.groupID))
                }
            }
            await persist()
            if markDirty {
                await syncDrainer.kick()
            }
        }
    }

    func group(id: UUID) -> ExpenseGroup? {
        groups.first { $0.id == id }
    }

    // MARK: - Mutations

    @discardableResult
    func createGroup(name: String, emoji: String?, currencyCode: String) async throws -> UUID {
        let now = Date()
        let memberID = UUID()
        let hostName = user.hasName ? user.name : "Me"
        let hostEmoji = user.emoji.isEmpty ? Member.defaultEmoji : user.emoji
        let host = Member(
            id: memberID,
            name: hostName,
            emoji: hostEmoji,
            joinedAt: now,
            userID: user.serverID
        )
        let group = ExpenseGroup(
            id: UUID(),
            name: name,
            emoji: emoji,
            currencyCode: currencyCode,
            members: [host],
            expenses: [],
            createdAt: now,
            updatedAt: now
        )
        groups.append(group)
        await syncState.markDirty(.group(group.id))
        await syncState.markDirty(.member(memberID, in: group.id))
        await persist()

        Task { await syncDrainer.kick() }
        return group.id
    }

    /// Removes a member from a group, both locally and server-side.
    ///
    /// Members referenced by expenses (as payer or participant) or by
    /// payments (as `from` or `to`) cannot be removed — their data
    /// would otherwise disappear from pickers while still being baked
    /// into historical splits, which makes expense edits inconsistent.
    /// In that case throws `memberHasExpenses(expenseCount:paymentCount:)`
    /// so the UI can surface a precise explanation.
    ///
    /// Local `archivedAt` hides the row from the UI immediately; the
    /// drainer then tombstones the membership server-side via
    /// `deleteMemberVersioned`. For a joined remote member this evicts
    /// them from the shared group — their next refresh sees `not_found`
    /// and the group drops from their local state.
    func removeMember(fromGroup groupID: UUID, memberID: UUID) async throws {
        guard let group = groups.first(where: { $0.id == groupID }) else {
            throw AppStoreError.groupNotFound
        }
        guard let member = group.members.first(where: { $0.id == memberID }) else {
            throw AppStoreError.memberNotInGroup
        }
        let expenseCount = group.expenses.filter {
            $0.payerID == memberID
                || $0.participantIDs.contains(memberID)
                || ($0.payments ?? []).contains(where: { $0.memberID == memberID })
                || ($0.shares ?? []).contains(where: { $0.memberID == memberID })
        }.count
        let paymentCount = (group.payments ?? []).filter {
            $0.fromMemberID == memberID || $0.toMemberID == memberID
        }.count
        if expenseCount > 0 || paymentCount > 0 {
            throw AppStoreError.memberHasExpenses(
                expenseCount: expenseCount,
                paymentCount: paymentCount
            )
        }
        try mutateGroupSync(groupID) { g in
            if let i = g.members.firstIndex(where: { $0.id == memberID }) {
                g.members[i].archivedAt = Date()
            }
        }
        let memberKey = EntityKey.member(memberID, in: groupID)
        await syncState.discardDraft(memberKey)
        await syncState.markTombstone(memberKey, lastKnownVersion: member.version)
        await persist()
        Task { await syncDrainer.kick() }
    }

    /// Updates a group's metadata (name, emoji, currency).
    ///
    /// When the currency code actually changes, every existing expense's
    /// snapshotted `exchangeRate` becomes stale (it converts to the OLD
    /// group currency, not the new one). Reset each expense to
    /// `exchangeRate = 1, ratePending = true` so `retryPendingRates`
    /// will re-fetch on next launch / scene-active. For expenses already
    /// denominated in the new currency, set `ratePending = false` (no
    /// fetch needed; rate stays 1). Each affected expense is marked
    /// dirty so the drainer pushes the new rate to the server.
    func updateGroup(id: UUID, name: String, emoji: String?, currencyCode: String) async throws {
        guard SupportedCurrencies.isSupported(currencyCode) else {
            throw AppStoreError.unsupportedCurrency
        }
        // Refuse currency change when the group has any recorded payments.
        // Payments are stored as raw Decimal in the group's currency (no
        // per-payment rate snapshot), so re-stamping the group currency
        // would silently re-interpret existing payment amounts. Until the
        // model carries per-payment currency, the user must delete payments
        // first.
        if let group = groups.first(where: { $0.id == id }),
           group.currencyCode != currencyCode,
           !(group.payments ?? []).isEmpty {
            throw AppStoreError.groupHasPayments
        }
        var dirtiedExpenseIDs: [UUID] = []
        try mutateGroupSync(id) { g in
            let currencyChanged = g.currencyCode != currencyCode
            g.name = name
            g.emoji = emoji
            g.currencyCode = currencyCode
            if currencyChanged {
                for i in g.expenses.indices {
                    g.expenses[i].exchangeRate = 1
                    g.expenses[i].ratePending = (g.expenses[i].currencyCode != currencyCode)
                    dirtiedExpenseIDs.append(g.expenses[i].id)
                }
            }
        }
        for eid in dirtiedExpenseIDs {
            await syncState.markDirty(.expense(eid, in: id))
        }
        await syncState.markDirty(.group(id))
        await persist()
        try await syncGroupMetadata(id: id)
        if !dirtiedExpenseIDs.isEmpty {
            Task { await syncDrainer.kick() }
            // Refresh in the background — retryPendingRates does the
            // FX work and persists/marks-dirty as rates land.
            Task { await retryPendingRates() }
        }
    }

    /// Archive hides a group from the main list but preserves all data.
    func archiveGroup(id: UUID) async throws {
        try mutateGroupSync(id, allowArchived: true) { g in g.archivedAt = Date() }
        await syncState.markDirty(.group(id))
        await persist()
        try await syncGroupMetadata(id: id)
    }

    func unarchiveGroup(id: UUID) async throws {
        try mutateGroupSync(id, allowArchived: true) { g in g.archivedAt = nil }
        await syncState.markDirty(.group(id))
        await persist()
        try await syncGroupMetadata(id: id)
    }

    /// Permanently deletes a group, including its receipt files on disk.
    /// Throws `forbidden` when the local user isn't the host of a shared
    /// group (the menu hides Delete in that case, but this is defense-in-
    /// depth for any future caller — e.g. swipe actions, scripted state).
    func deleteGroup(id: UUID) async throws {
        guard let group = groups.first(where: { $0.id == id }) else {
            throw AppStoreError.groupNotFound
        }
        if isShared(id) && !isHost(of: id) {
            throw AppStoreError.forbidden
        }
        // Order matters: cleanUpLocalGroup wipes every SyncState entry for
        // this groupID (including any group-level dirty / tombstone), so
        // mark the group tombstone *after* the cleanup or the DELETE never
        // ships.
        await cleanUpLocalGroup(id)
        await syncState.markTombstone(.group(group.id), lastKnownVersion: group.version)
        await persist()
        Task { await syncDrainer.kick() }
    }

    /// In-memory + on-disk cleanup for a group that's being removed locally.
    /// Drops the group from `groups`, deletes all receipt files referenced
    /// by its expenses, prunes its activity-log entries, clears any
    /// matching `pendingDeletion`, purges every `SyncState` dirty entry,
    /// tombstone, and rejected draft keyed to this group, and removes any
    /// conflict banner that targets the group. Caller is responsible for
    /// `persist()`. If a caller wants the server to receive a DELETE for
    /// this group, it must `markTombstone(.group(...))` **after** calling
    /// this method — `clearAllForGroup` would otherwise sweep the just-set
    /// tombstone.
    private func cleanUpLocalGroup(_ groupID: UUID) async {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let group = groups[gi]
        let receiptStore = ReceiptStore.default()
        for expense in group.expenses {
            for receipt in expense.receipts {
                receiptStore.delete(id: receipt.id)
            }
        }
        if pendingDeletion?.groupID == groupID { pendingDeletion = nil }
        activityLog.removeAll { $0.groupID == groupID }
        groups.remove(at: gi)
        await syncState.clearAllForGroup(groupID)
        conflictBanners.removeAll { banner in
            switch banner.kind {
            case .expense(let gid, _),
                 .payment(let gid, _),
                 .member(let gid, _),
                 .group(let gid),
                 .groupDeleted(let gid, _),
                 .removedFromGroup(let gid, _),
                 .permissionDenied(let gid, _, _),
                 .receiptTooLarge(let gid, _):
                return gid == groupID
            }
        }
    }

    /// True iff the current authenticated user still has a live seat in a
    /// synced group (or is its host). Used by the refresh/reconcile paths
    /// to evict groups the host has removed us from server-side.
    ///
    /// Returns `true` (preserve the group) in any case where we can't
    /// confidently judge:
    ///   - Local-only groups (never synced).
    ///   - Anonymous user (no `serverID` to match against memberships).
    /// The host check (`ownerUserID == me`) is defense-in-depth — hosts
    /// can't be kicked, but if the server ever stops returning the host's
    /// own seat in `memberships`, we'd still keep the group.
    private func currentUserStillBelongs(to group: ExpenseGroup) -> Bool {
        if !isShared(group.id) { return true }
        guard let me = user.serverID else { return true }
        if group.ownerUserID == me { return true }
        return group.members.contains { $0.userID == me && $0.archivedAt == nil }
    }

    /// Mirrors the Rails backend's `can_edit?(expense)` rule: an expense
    /// can be edited or deleted by the group host, the (primary) payer,
    /// any listed co-payer, or any participant in the split. Used by the
    /// UI to hide / disable mutation affordances so an unauthorized user
    /// doesn't round-trip a 403.
    ///
    /// Local-only groups (never synced) and anonymous callers (no
    /// `serverID`) bypass the check — the server gates the request later
    /// if we ever start syncing.
    func canEditExpense(_ expense: Expense, in group: ExpenseGroup) -> Bool {
        if !isShared(group.id) { return true }
        guard let me = user.serverID else { return true }
        if group.ownerUserID == me { return true }
        let memberUserID: (UUID) -> UUID? = { memberID in
            group.members.first(where: { $0.id == memberID })?.userID
        }
        if memberUserID(expense.payerID) == me { return true }
        if let payments = expense.payments {
            for p in payments where memberUserID(p.memberID) == me { return true }
        }
        var splitMemberIDs = Set(expense.participantIDs)
        if let shares = expense.shares {
            for s in shares { splitMemberIDs.insert(s.memberID) }
        }
        for mid in splitMemberIDs where memberUserID(mid) == me { return true }
        return false
    }

    /// Drops a synced group from local state because the current user is
    /// no longer a member, posting an informational banner so the user
    /// knows why the group disappeared. Mirrors the `groupDeleted` path
    /// in `refresh(groupID:)` but with a distinct banner kind.
    private func evictGroupRemovedByHost(_ groupID: UUID) async {
        // Suppress eviction inside the post-accept grace window. A concurrent
        // GET that raced the accept's membership-creation transaction can
        // return us as a non-member; trusting it would re-post the "removed"
        // banner and yank the just-joined group out from under the user. The
        // next refresh after the window closes will evict correctly if the
        // host really did remove us.
        if let acceptedAt = recentInviteAccepts[groupID],
           Date().timeIntervalSince(acceptedAt) < Self.inviteAcceptGracePeriod {
            return
        }
        guard let removed = groups.first(where: { $0.id == groupID }) else { return }
        await cleanUpLocalGroup(groupID)
        conflictBanners.append(
            ConflictBanner(kind: .removedFromGroup(groupID: groupID, name: removed.name))
        )
    }

    /// True iff the current user is the host of the group.
    ///
    /// Default-to-host when ownership is unknown so users aren't locked
    /// out of Delete on:
    ///   - local-only groups (`ownerUserID == nil`)
    ///   - groups synced before this build started populating `ownerUserID`
    ///     (will self-correct after one refresh)
    ///   - groups where the local user has no serverID yet (anonymous,
    ///     pre-registration) — only a single-device host could have
    ///     created the group locally.
    ///
    /// Returns false only when we KNOW the owner and it isn't the current
    /// user (i.e., both `ownerUserID` and `user.serverID` are non-nil and
    /// they don't match).
    func isHost(of groupID: UUID) -> Bool {
        guard let group = groups.first(where: { $0.id == groupID }) else { return false }
        guard let owner = group.ownerUserID else { return true }
        guard let me = user.serverID else { return false }
        return owner == me
    }

    /// Once-per-launch (or scene-active) sweep: any receipt with no server
    /// acknowledgment yet (`uploaderUserID == nil`) on a synced group gets
    /// marked dirty so the drainer ships it. The server's POST endpoint is
    /// idempotent on `receipt_id` (with_idempotency block), so re-running
    /// this against already-uploaded receipts is harmless — they'll just
    /// 200 back with the same row and a fresh group refresh will set
    /// `uploaderUserID`.
    func reconcilePreSyncReceipts() async {
        for group in groups where isShared(group.id) {
            for expense in group.expenses {
                for receipt in expense.receipts where receipt.uploaderUserID == nil {
                    // markDirty re-queues the key; if a previous session left a
                    // step persisted (.bytesPending/.finalizePending), leave it
                    // alone so the drainer resumes from the right place instead
                    // of re-POSTing and re-PUTing already-uploaded bytes. New
                    // receipts default to .metadataPending via
                    // SyncState.receiptStep(for:)'s nil-coalescing fallback.
                    await syncState.markDirty(.receipt(receipt.id, in: group.id))
                }
            }
        }
        Task { await syncDrainer.kick() }
    }

    /// True iff the current user is allowed to delete this receipt — mirrors
    /// the server's rule (`receipts_controller.rb`: host OR uploader). A
    /// receipt with `uploaderUserID == nil` is treated as locally-created
    /// (added in the editor session, not yet acked by the server) so we
    /// always allow delete; the next group refresh will assign an
    /// uploaderUserID and the permission firms up.
    func canDeleteReceipt(_ receipt: ReceiptAttachment, in group: ExpenseGroup) -> Bool {
        if receipt.uploaderUserID == nil { return true }
        if isHost(of: group.id) { return true }
        guard let me = user.serverID else { return false }
        return receipt.uploaderUserID == me
    }

    /// True iff the group has been synced to the server (has an ownerUserID
    /// or non-zero version). Used to gate "Leave group" affordance — local-
    /// only groups don't have a "leave" semantic, only "delete".
    func isShared(_ groupID: UUID) -> Bool {
        guard let group = groups.first(where: { $0.id == groupID }) else { return false }
        return group.ownerUserID != nil || group.version > 0
    }

    /// Removes the current user's membership from a shared group server-side
    /// and drops the group from local state on success. Throws if the user
    /// has no Member seat in the group, or if the server rejects (e.g., host
    /// can't leave their own group — they must Delete).
    @MainActor
    func leaveGroup(_ groupID: UUID) async throws {
        guard let group = groups.first(where: { $0.id == groupID }) else {
            throw AppStoreError.groupNotFound
        }
        guard let serverID = user.serverID else {
            throw AppStoreError.memberNotInGroup
        }
        guard let mySeat = group.members.first(where: { $0.userID == serverID }) else {
            throw AppStoreError.memberNotInGroup
        }

        // Server-side soft-delete of our membership. Use the existing
        // versioned-delete path (mirrors the path SyncDrainer uses).
        let memberKey = EntityKey.member(mySeat.id, in: groupID)
        let outcome: MutationOutcome<Void>
        do {
            outcome = try await repository.deleteMemberVersioned(
                id: mySeat.id,
                in: groupID,
                ifMatchVersion: mySeat.version
            )
        } catch {
            // Transport failure (offline, server down): tombstone the seat so
            // the next drain retries the DELETE. The local group stays visible
            // and the user sees the thrown error so they can retry.
            await syncState.markTombstone(memberKey, lastKnownVersion: mySeat.version)
            Task { await syncDrainer.kick() }
            throw error
        }
        // staleWrite means our cached version was wrong; treat as
        // "membership already different" — surface as an error so the user
        // can refresh and retry. Don't tombstone (a retry with the same
        // stale version would just 409 again).
        if case .staleWrite = outcome {
            throw AppStoreError.memberNotInGroup
        }

        // Drop the group from local state, including receipt files and
        // activity-log entries. Mirrors deleteGroup's on-disk cleanup so
        // leaving doesn't orphan data.
        await cleanUpLocalGroup(groupID)
        await persist()
    }

    /// Groups the user should see in the main list and Dashboard — archived groups excluded.
    var activeGroups: [ExpenseGroup] { groups.filter { $0.archivedAt == nil } }

    /// Archived groups, most-recently-archived first.
    var archivedGroups: [ExpenseGroup] {
        groups.filter { $0.archivedAt != nil }.sorted {
            ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast)
        }
    }

    @discardableResult
    func addExpense(
        toGroup groupID: UUID,
        payerID: UUID,
        amount: Decimal,
        currencyCode: String,
        description: String,
        date: Date,
        participantIDs: [UUID],
        category: ExpenseCategory,
        receipts: [ReceiptAttachment],
        shares: [ExpenseShare]? = nil,
        payments: [ExpensePayment]? = nil,
        splitKind: String? = nil
    ) async throws -> UUID {
        guard let group = groups.first(where: { $0.id == groupID }) else {
            throw AppStoreError.groupNotFound
        }
        guard amount > 0 else { throw AppStoreError.invalidExpense }
        let memberIDs = Set(group.members.map(\.id))
        guard memberIDs.contains(payerID) else { throw AppStoreError.memberNotInGroup }
        guard participantIDs.allSatisfy({ memberIDs.contains($0) }) else {
            throw AppStoreError.memberNotInGroup
        }
        guard SupportedCurrencies.isSupported(currencyCode) else {
            throw AppStoreError.unsupportedCurrency
        }

        // Validate and normalize custom shares when provided.
        let validatedShares: [ExpenseShare]?
        let effectiveParticipantIDs: [UUID]
        if let shares, !shares.isEmpty {
            for share in shares where !memberIDs.contains(share.memberID) {
                throw AppStoreError.memberNotInGroup
            }
            let sum = shares.reduce(Decimal(0)) { $0 + $1.amount }
            if abs(sum - amount) > Decimal(0.01) {
                throw AppStoreError.splitAmountMismatch
            }
            validatedShares = shares
            effectiveParticipantIDs = shares.map(\.memberID)
        } else {
            validatedShares = nil
            effectiveParticipantIDs = participantIDs
        }

        // Validate multi-payer payments when provided (same tolerance as
        // shares). Filter zero-amount entries — the form may emit them
        // for unchecked rows.
        let validatedPayments = try Self.validatePayments(
            payments,
            amount: amount,
            memberIDs: memberIDs
        )

        let (rate, pending) = await fetchRate(from: currencyCode, to: group.currencyCode, on: date)

        let newID = UUID()
        let expense = Expense(
            id: newID,
            payerID: payerID,
            amount: amount,
            description: description.trimmingCharacters(in: .whitespaces),
            date: date,
            participantIDs: effectiveParticipantIDs,
            category: category,
            receipts: receipts,
            currencyCode: currencyCode,
            exchangeRate: rate,
            ratePending: pending,
            shares: validatedShares,
            payments: validatedPayments,
            splitKind: validatedShares == nil ? nil : splitKind
        )

        try mutateGroupSync(groupID) { g in
            g.expenses.append(expense)
        }
        await syncState.markDirty(.expense(newID, in: groupID))
        for receipt in receipts {
            await syncState.markDirty(.receipt(receipt.id, in: groupID))
            await syncState.setReceiptStep(.metadataPending, for: receipt.id)
        }
        await persist()

        Task { await syncDrainer.kick() }
        return newID
    }

    func editExpense(
        id: UUID,
        inGroup groupID: UUID,
        payerID: UUID,
        amount: Decimal,
        currencyCode: String,
        description: String,
        date: Date,
        participantIDs: [UUID],
        category: ExpenseCategory,
        receipts: [ReceiptAttachment],
        shares: [ExpenseShare]? = nil,
        payments: [ExpensePayment]? = nil,
        splitKind: String? = nil
    ) async throws {
        guard let group = groups.first(where: { $0.id == groupID }) else {
            throw AppStoreError.groupNotFound
        }
        guard amount > 0 else { throw AppStoreError.invalidExpense }
        guard let before = group.expenses.first(where: { $0.id == id }) else {
            throw AppStoreError.expenseNotFound
        }
        // Allow references that were already in the saved expense — the
        // original PUT already validated them against a live roster on the
        // server, and the membership row still exists there (e.g. a "ghost"
        // membership after the owning user deletes their account). Without
        // this, an edit on User A's device fails locally with
        // `memberNotInGroup` if User B's membership has been transiently
        // evicted from local state, even though A's intent is to preserve
        // the original split. NEW additions (participants/payer/shares/
        // payments not in the original) still require live local membership
        // so we don't accept arbitrary phantom IDs from the UI.
        let memberIDs = Set(group.members.map(\.id))
        let legacyRefs: Set<UUID> = {
            var s: Set<UUID> = [before.payerID]
            s.formUnion(before.participantIDs)
            if let originals = before.shares { s.formUnion(originals.map(\.memberID)) }
            if let originals = before.payments { s.formUnion(originals.map(\.memberID)) }
            return s
        }()
        let allowedRefs = memberIDs.union(legacyRefs)
        guard allowedRefs.contains(payerID) else { throw AppStoreError.memberNotInGroup }
        guard participantIDs.allSatisfy({ allowedRefs.contains($0) }) else {
            throw AppStoreError.memberNotInGroup
        }
        guard SupportedCurrencies.isSupported(currencyCode) else {
            throw AppStoreError.unsupportedCurrency
        }

        // Validate and normalize custom shares when provided.
        let validatedShares: [ExpenseShare]?
        let effectiveParticipantIDs: [UUID]
        if let shares, !shares.isEmpty {
            for share in shares where !allowedRefs.contains(share.memberID) {
                throw AppStoreError.memberNotInGroup
            }
            let sum = shares.reduce(Decimal(0)) { $0 + $1.amount }
            if abs(sum - amount) > Decimal(0.01) {
                throw AppStoreError.splitAmountMismatch
            }
            validatedShares = shares
            effectiveParticipantIDs = shares.map(\.memberID)
        } else {
            validatedShares = nil
            effectiveParticipantIDs = participantIDs
        }

        // Validate multi-payer payments (same semantics as addExpense, with
        // the same legacy-ref allowance so a ghost payer stays acceptable).
        let validatedPayments = try Self.validatePayments(
            payments,
            amount: amount,
            memberIDs: allowedRefs
        )

        let needsRefetch = before.currencyCode != currencyCode || before.date != date || before.ratePending
        let rate: Decimal
        let pending: Bool
        if needsRefetch {
            let result = await fetchRate(from: currencyCode, to: group.currencyCode, on: date)
            rate = result.rate
            pending = result.pending
        } else {
            rate = before.exchangeRate
            pending = before.ratePending
        }

        var changes: [String] = []
        var afterDescription = ""
        try mutateGroupSync(groupID) { g in
            guard let i = g.expenses.firstIndex(where: { $0.id == id }) else {
                throw AppStoreError.expenseNotFound
            }
            var after = Expense(
                id: id,
                payerID: payerID,
                amount: amount,
                description: description.trimmingCharacters(in: .whitespaces),
                date: date,
                participantIDs: effectiveParticipantIDs,
                category: category,
                receipts: receipts,
                currencyCode: currencyCode,
                exchangeRate: rate,
                ratePending: pending,
                shares: validatedShares,
                payments: validatedPayments,
                splitKind: validatedShares == nil ? nil : splitKind,
                updatedAt: g.expenses[i].updatedAt,
                deletedAt: g.expenses[i].deletedAt
            )
            after.version = g.expenses[i].version
            changes = Self.describeChanges(before: g.expenses[i], after: after, members: g.members)
            afterDescription = after.description
            g.expenses[i] = after
        }

        if !changes.isEmpty {
            activityLog.append(ActivityEntry(
                id: UUID(),
                date: Date(),
                groupID: groupID,
                kind: .expenseEdited(expenseID: id, description: afterDescription, changes: changes),
                editorName: currentEditorName(in: groupID)
            ))
        }
        await syncState.markDirty(.expense(id, in: groupID))

        // Diff receipts: mark added ones dirty (metadataPending) and tombstone
        // removed ones. File cleanup is deferred to applyDelete(.receipt) so
        // the drainer can still read bytes if a pushReceipt retry is in flight.
        // Parent expense is marked dirty first to match the drain-order invariant
        // (parents before children on upserts).
        let beforeReceiptIDs = Set(before.receipts.map(\.id))
        let afterReceiptIDs = Set(receipts.map(\.id))
        let addedReceiptIDs = afterReceiptIDs.subtracting(beforeReceiptIDs)
        let removedReceiptIDs = beforeReceiptIDs.subtracting(afterReceiptIDs)
        for rid in addedReceiptIDs {
            await syncState.markDirty(.receipt(rid, in: groupID))
            await syncState.setReceiptStep(.metadataPending, for: rid)
        }
        for rid in removedReceiptIDs {
            // Receipts have no server-side version; pass 0.
            await syncState.markTombstone(.receipt(rid, in: groupID), lastKnownVersion: 0)
        }
        await persist()

        Task { await syncDrainer.kick() }
    }

    // MARK: - Delete with undo

    func beginDeleteExpense(id: UUID, inGroup groupID: UUID) async throws {
        if let existing = pendingDeletion, !pendingDeletionMatches(existing, expenseID: id, groupID: groupID) {
            await commitPendingDeletion()
        }
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else {
            throw AppStoreError.groupNotFound
        }
        guard let ei = groups[gi].expenses.firstIndex(where: { $0.id == id }) else {
            throw AppStoreError.expenseNotFound
        }
        let expense = groups[gi].expenses[ei]
        let groupName = groups[gi].name
        groups[gi].expenses.remove(at: ei)
        pendingDeletion = PendingDeletion(
            id: UUID(),
            groupID: groupID,
            groupName: groupName,
            kind: .expense(expense, originalIndex: ei),
            startedAt: Date()
        )
        await persist()
    }

    private func pendingDeletionMatches(
        _ pending: PendingDeletion,
        expenseID: UUID,
        groupID: UUID
    ) -> Bool {
        guard pending.groupID == groupID else { return false }
        if case .expense(let e, _) = pending.kind { return e.id == expenseID }
        return false
    }

    func undoPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        if let gi = groups.firstIndex(where: { $0.id == pending.groupID }) {
            switch pending.kind {
            case .expense(let expense, let originalIndex):
                let clamped = min(originalIndex, groups[gi].expenses.count)
                groups[gi].expenses.insert(expense, at: clamped)
            case .payment(let payment, let originalIndex, _):
                var payments = groups[gi].payments ?? []
                let clamped = min(originalIndex, payments.count)
                payments.insert(payment, at: clamped)
                groups[gi].payments = payments
            }
            Task { await self.persist() }
        }
        pendingDeletion = nil
    }

    func commitPendingDeletion() async {
        guard let pending = pendingDeletion else { return }
        switch pending.kind {
        case .expense(let expense, _):
            let payerName = groups.first(where: { $0.id == pending.groupID })?
                .members.first(where: { $0.id == expense.payerID })?.name ?? "Unknown"
            activityLog.append(ActivityEntry(
                id: UUID(),
                date: Date(),
                groupID: pending.groupID,
                kind: .expenseDeleted(
                    expenseID: expense.id,
                    description: expense.description,
                    amount: expense.amount,
                    currencyCode: expense.currencyCode,
                    payerName: payerName
                )
            ))
            let store = ReceiptStore.default()
            for r in expense.receipts {
                store.delete(id: r.id)
            }
        case .payment(let payment, _, let snapshotCurrency):
            let group = groups.first(where: { $0.id == pending.groupID })
            let fromName = group?.members.first(where: { $0.id == payment.fromMemberID })?.name ?? "Unknown"
            let toName = group?.members.first(where: { $0.id == payment.toMemberID })?.name ?? "Unknown"
            // Prefer the live group's current currencyCode (in case it
            // changed during the snackbar window — unlikely but possible);
            // fall back to the snapshot from beginDeletePayment so we never
            // emit an empty string into the activity feed.
            let currencyCode = group?.currencyCode ?? snapshotCurrency
            activityLog.append(ActivityEntry(
                id: UUID(),
                date: Date(),
                groupID: pending.groupID,
                kind: .paymentDeleted(
                    paymentID: payment.id,
                    fromMemberName: fromName,
                    toMemberName: toName,
                    amount: payment.amount,
                    currencyCode: currencyCode
                )
            ))
        }

        // Remote dispatch.
        switch pending.kind {
        case .expense(let expense, _):
            // Tombstone the expense; drainer will DELETE.
            await syncState.markTombstone(.expense(expense.id, in: pending.groupID), lastKnownVersion: expense.version)
            Task { await syncDrainer.kick() }
        case .payment(let payment, _, _):
            await syncState.markTombstone(.payment(payment.id, in: pending.groupID), lastKnownVersion: payment.version)
            Task { await syncDrainer.kick() }
        }

        pendingDeletion = nil
        await persist()
    }

    /// Reverses the backfill applied at invite accept: strips the new
    /// member from `participantIDs` of every expense in the pending set,
    /// marks them dirty so the drainer pushes the reversal, and clears
    /// `pendingBackfill`. Called by the `BackfillSnackbar`'s Undo button.
    /// Idempotent — calling with no pending state is a no-op.
    func undoPendingBackfill() async {
        guard let pending = pendingBackfill else { return }
        pendingBackfill = nil

        try? mutateGroupSync(pending.groupID) { g in
            for id in pending.expenseIDs {
                guard let i = g.expenses.firstIndex(where: { $0.id == id }) else { continue }
                g.expenses[i].participantIDs.removeAll { $0 == pending.memberID }
            }
        }
        for id in pending.expenseIDs {
            await syncState.markDirty(.expense(id, in: pending.groupID))
        }
        await persist()
        Task { await syncDrainer.kick() }
    }

    /// Clears the pending-backfill state without performing any sync work.
    /// Called by the `BackfillSnackbar`'s auto-dismiss timer (6s default).
    /// Undo is a separate path that actively reverses the participant
    /// changes — see `undoPendingBackfill`.
    func dismissPendingBackfill() {
        pendingBackfill = nil
    }

    // MARK: - Payments

    @discardableResult
    func recordPayment(
        inGroup groupID: UUID,
        fromMemberID: UUID,
        toMemberID: UUID,
        amount: Decimal,
        date: Date,
        note: String?,
        expenseIDs: [UUID]? = nil
    ) async throws -> UUID {
        guard let group = groups.first(where: { $0.id == groupID }) else {
            throw AppStoreError.groupNotFound
        }
        guard fromMemberID != toMemberID else { throw AppStoreError.invalidPayment }
        guard amount > 0 else { throw AppStoreError.invalidPayment }
        let activeMemberIDs = Set(group.members.filter { $0.archivedAt == nil }.map(\.id))
        guard activeMemberIDs.contains(fromMemberID),
              activeMemberIDs.contains(toMemberID) else {
            throw AppStoreError.memberNotInGroup
        }

        // Filter to IDs that actually resolve to a live expense in this group.
        // Other clients may have deleted one of them while the sheet was open.
        let validatedExpenseIDs: [UUID]?
        if let ids = expenseIDs, !ids.isEmpty {
            let liveExpenseIDs = Set(group.expenses.filter { $0.deletedAt == nil }.map(\.id))
            let filtered = ids.filter { liveExpenseIDs.contains($0) }
            validatedExpenseIDs = filtered.isEmpty ? nil : filtered
        } else {
            validatedExpenseIDs = nil
        }

        let id = UUID()
        let payment = Payment(
            id: id,
            fromMemberID: fromMemberID,
            toMemberID: toMemberID,
            amount: amount,
            date: date,
            note: trimmedNote(note),
            expenseIDs: validatedExpenseIDs
        )
        try mutateGroupSync(groupID) { g in
            var payments = g.payments ?? []
            payments.append(payment)
            g.payments = payments
        }
        await syncState.markDirty(.payment(id, in: groupID))
        await persist()

        Task { await syncDrainer.kick() }
        return id
    }

    func editPayment(
        id: UUID,
        inGroup groupID: UUID,
        fromMemberID: UUID,
        toMemberID: UUID,
        amount: Decimal,
        date: Date,
        note: String?,
        expenseIDs: [UUID]? = nil
    ) async throws {
        guard let group = groups.first(where: { $0.id == groupID }) else {
            throw AppStoreError.groupNotFound
        }
        guard fromMemberID != toMemberID else { throw AppStoreError.invalidPayment }
        guard amount > 0 else { throw AppStoreError.invalidPayment }
        let activeMemberIDs = Set(group.members.filter { $0.archivedAt == nil }.map(\.id))
        guard activeMemberIDs.contains(fromMemberID),
              activeMemberIDs.contains(toMemberID) else {
            throw AppStoreError.memberNotInGroup
        }
        guard let beforePayment = (group.payments ?? []).first(where: { $0.id == id }) else {
            throw AppStoreError.paymentNotFound
        }

        let validatedExpenseIDs: [UUID]?
        if let ids = expenseIDs, !ids.isEmpty {
            let liveExpenseIDs = Set(group.expenses.filter { $0.deletedAt == nil }.map(\.id))
            let filtered = ids.filter { liveExpenseIDs.contains($0) }
            validatedExpenseIDs = filtered.isEmpty ? nil : filtered
        } else {
            validatedExpenseIDs = nil
        }

        var changes: [String] = []
        var fromName = ""
        var toName = ""
        try mutateGroupSync(groupID) { g in
            var payments = g.payments ?? []
            guard let pi = payments.firstIndex(where: { $0.id == id }) else {
                throw AppStoreError.paymentNotFound
            }
            var after = payments[pi]
            after.fromMemberID = fromMemberID
            after.toMemberID = toMemberID
            after.amount = amount
            after.date = date
            after.note = trimmedNote(note)
            after.expenseIDs = validatedExpenseIDs
            changes = Self.describePaymentChanges(
                before: beforePayment,
                after: after,
                groupCurrency: g.currencyCode,
                members: g.members
            )
            fromName = g.members.first(where: { $0.id == fromMemberID })?.name ?? "Unknown"
            toName = g.members.first(where: { $0.id == toMemberID })?.name ?? "Unknown"
            payments[pi] = after
            g.payments = payments
        }

        if !changes.isEmpty {
            activityLog.append(ActivityEntry(
                id: UUID(),
                date: Date(),
                groupID: groupID,
                kind: .paymentEdited(
                    paymentID: id,
                    fromMemberName: fromName,
                    toMemberName: toName,
                    changes: changes
                ),
                editorName: currentEditorName(in: groupID)
            ))
        }
        await syncState.markDirty(.payment(id, in: groupID))
        await persist()

        Task { await syncDrainer.kick() }
    }

    func beginDeletePayment(id: UUID, inGroup groupID: UUID) async throws {
        if let existing = pendingDeletion, !pendingDeletionMatches(existing, paymentID: id, groupID: groupID) {
            await commitPendingDeletion()
        }
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else {
            throw AppStoreError.groupNotFound
        }
        var payments = groups[gi].payments ?? []
        guard let pi = payments.firstIndex(where: { $0.id == id }) else {
            throw AppStoreError.paymentNotFound
        }
        let payment = payments[pi]
        let groupName = groups[gi].name
        let snapshotCurrency = groups[gi].currencyCode
        payments.remove(at: pi)
        groups[gi].payments = payments
        pendingDeletion = PendingDeletion(
            id: UUID(),
            groupID: groupID,
            groupName: groupName,
            kind: .payment(payment, originalIndex: pi, currencyCode: snapshotCurrency),
            startedAt: Date()
        )
        await persist()
    }

    private func trimmedNote(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Resolves the local user's display name for activity-log attribution
    /// of edits. Prefers the user's seat in the group (so a renamed seat
    /// is honored over the global Settings name); falls back to the User
    /// object's name; returns nil if no name is set yet (anonymous +
    /// no onboarding).
    private func currentEditorName(in groupID: UUID) -> String? {
        if let group = groups.first(where: { $0.id == groupID }),
           let me = userMember(in: group) {
            return me.name
        }
        return user.hasName ? user.name : nil
    }

    private func pendingDeletionMatches(
        _ pending: PendingDeletion,
        paymentID: UUID,
        groupID: UUID
    ) -> Bool {
        guard pending.groupID == groupID else { return false }
        if case .payment(let p, _, _) = pending.kind { return p.id == paymentID }
        return false
    }

    func setDefaultCurrencyCode(_ code: String) async throws {
        defaultCurrencyCode = code
        await persist()
    }

    func resetAll() async throws {
        groups = []
        activityLog = []
        pendingDeletion = nil
        conflictBanners.removeAll()
        drafts.removeAll()
        await syncState.wipe()
        user = User.empty
        await persist()
    }

    // MARK: - Sync

    /// Throttle + coalesce wrapper around the actual refresh body. Callers
    /// without `force: true` skip the network call when this group was
    /// refreshed within `refreshThrottleInterval`. Concurrent callers
    /// piggyback on the in-flight Task so duplicate requests collapse to
    /// a single GET.
    ///
    /// Pass `force: true` for user gestures (pull-to-refresh) and just-
    /// happened events (notification tap, cold launch) where the caller
    /// has a concrete reason to bypass staleness — leave it `false` for
    /// opportunistic navigation hooks (view appear, pop-back) so the
    /// store decides whether the call is wasteful.
    @MainActor
    func refresh(groupID: UUID, force: Bool = false) async {
        if let inFlight = inFlightRefresh[groupID] {
            await inFlight.value
            return
        }
        if !force,
           let last = lastRefreshAt[groupID],
           Date().timeIntervalSince(last) < Self.refreshThrottleInterval {
            return
        }
        let task = Task<Void, Never> { [weak self] in
            await self?.performGroupRefresh(groupID: groupID)
        }
        inFlightRefresh[groupID] = task
        await task.value
        inFlightRefresh[groupID] = nil
        lastRefreshAt[groupID] = Date()
    }

    /// Pull a fresh copy of one group from the server. No-op when not signed-in.
    ///
    /// `@MainActor` so all `groups` mutations serialize with the rest of
    /// AppStore. Indices captured *before* the awaits below are not safe to
    /// reuse afterwards: other main-actor work (foregroundRefresh's sibling
    /// tasks, user-driven deletes) can shift `groups` between suspension and
    /// resumption. Always re-look up by ID after the awaits.
    @MainActor
    private func performGroupRefresh(groupID: UUID) async {
        guard isSignedInProvider() else { return }
        do {
            let server = try await repository.refresh(groupID: groupID)
            // Snapshot dirty/tombstone keys once; the merge runs synchronously below.
            let dirtyKeys = await syncState.dirty
            let tombstoneKeys = Set(await syncState.tombstones.keys)
            let editing = activeEditingEntity
            // Re-look up idx after the suspensions above — array may have shifted.
            // Cold-cache case (notification tap on a group the user hasn't
            // synced yet): append the server snapshot and bail out before
            // the merge, which is only useful when there's local state to
            // reconcile against. Without this branch, EditExpenseView opened
            // from a push lands on "Expense not found" until the next
            // foregroundRefresh.
            guard let idx = groups.firstIndex(where: { $0.id == groupID }) else {
                groups.append(server)
                await persist()
                return
            }
            let local = groups[idx]

            // Group-level fields: merge unless the group itself is dirty/tombstoned.
            let groupKey = EntityKey.group(groupID)
            let groupSkipped = dirtyKeys.contains(groupKey) || tombstoneKeys.contains(groupKey)
            var merged = local
            if !groupSkipped {
                merged.name = server.name
                merged.emoji = server.emoji
                merged.currencyCode = server.currencyCode
                merged.archivedAt = server.archivedAt
                merged.updatedAt = server.updatedAt
                merged.version = server.version
            }

            // Expenses: per-entity dirty/tombstone/active-editor merge.
            merged.expenses = mergeChildren(
                local: local.expenses,
                server: server.expenses,
                groupID: groupID,
                kind: .expense,
                dirty: dirtyKeys,
                tombstones: tombstoneKeys,
                editing: editing
            )
            // Payments: same.
            let mergedPayments = mergeChildren(
                local: local.payments ?? [],
                server: server.payments ?? [],
                groupID: groupID,
                kind: .payment,
                dirty: dirtyKeys,
                tombstones: tombstoneKeys,
                editing: editing
            )
            merged.payments = mergedPayments.isEmpty ? local.payments : mergedPayments
            // Members: same, but preserve any local member id that's still
            // referenced by a surviving expense/payment so the merge can't
            // strand the expense pointing at a dropped member.
            let referencedMemberIDs = Self.memberIDsReferenced(
                expenses: merged.expenses,
                payments: merged.payments ?? []
            )
            merged.members = mergeChildren(
                local: local.members,
                server: server.members,
                groupID: groupID,
                kind: .member,
                dirty: dirtyKeys,
                tombstones: tombstoneKeys,
                editing: editing,
                preserveIDs: referencedMemberIDs
            )

            groups[idx] = merged
            // If the merge dropped our own seat (host kicked us — server
            // returned the group without our membership), evict the group
            // locally. The design comment on `removeMember` predicted the
            // server would return `not_found`, but in practice it returns
            // 200 with our seat omitted, so this is the only signal the
            // refresh path gets.
            if !currentUserStillBelongs(to: merged) {
                await evictGroupRemovedByHost(groupID)
            }
            await persist()
        } catch APIError.server(let code, _, _, _) where code == "not_found" {
            // Group was deleted on the server. The await above suspended, so
            // re-look up by ID — the original idx may now be stale or OOB.
            guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
            let removed = groups.remove(at: idx)
            conflictBanners.append(ConflictBanner(kind: .groupDeleted(groupID: groupID, name: removed.name)))
            await persist()
        } catch {
            // Repository error etc. — log and ignore.
        }
    }

    /// Per-entity merge for refresh: server wins for clean entities, local wins
    /// for dirty/tombstoned/active-editor entities. Entries the server omits
    /// are dropped from local (server confirmed delete) unless local has them
    /// dirty or tombstoned.
    ///
    /// `preserveIDs` is a safety net for the member-merge case: a member whose
    /// id is still referenced by a live expense or payment must NOT be dropped
    /// from the local roster even if the server transiently omits them.
    /// Otherwise the next render computes balances against orphan IDs (phantom
    /// dict entries → non-zero per-member sum → debt-simplifier assertion) and
    /// the editor can't save edits that touch them. Mirrors the in-line
    /// payments / expenses skips in BalanceCalculator.
    private func mergeChildren<T: Identifiable>(
        local: [T],
        server: [T],
        groupID: UUID,
        kind: EntityKind,
        dirty: Set<EntityKey>,
        tombstones: Set<EntityKey>,
        editing: (groupID: UUID, entityID: UUID)?,
        preserveIDs: Set<UUID> = []
    ) -> [T] where T.ID == UUID {
        var byID: [UUID: T] = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let serverIDs = Set(server.map { $0.id })

        for s in server {
            let key = EntityKey(kind: kind, id: s.id, groupID: groupID)
            if dirty.contains(key) { continue }                    // local has unpushed changes
            if tombstones.contains(key) { continue }               // local intends to delete
            if let e = editing, e.groupID == groupID, e.entityID == s.id { continue }  // active-editor
            byID[s.id] = s
        }
        // Drop entities the server no longer returns, unless local has them
        // dirty / tombstoned, or they're still referenced by surviving
        // siblings (members referenced by an expense/payment).
        for id in byID.keys where !serverIDs.contains(id) {
            let key = EntityKey(kind: kind, id: id, groupID: groupID)
            if dirty.contains(key) { continue }
            if tombstones.contains(key) { continue }
            if preserveIDs.contains(id) { continue }
            byID.removeValue(forKey: id)
        }
        // Preserve original local ordering for surviving entities; append new ones.
        var ordered: [T] = []
        var seen = Set<UUID>()
        for l in local where byID[l.id] != nil {
            ordered.append(byID[l.id]!)
            seen.insert(l.id)
        }
        for s in server where !seen.contains(s.id) {
            if let v = byID[s.id] { ordered.append(v) }
        }
        return ordered
    }

    /// Refresh every group from the server. No-op when not signed-in. Bounded concurrency = 4.
    ///
    /// `@MainActor` so the bounded-concurrency loop reads `groups` consistently
    /// and so the per-group `refresh` calls inherit main-actor isolation for
    /// mutation. Network I/O still runs off-main inside `repository.refresh`.
    ///
    /// Per-group throttling lives in `refresh(groupID:force:)` so calling
    /// this method from multiple navigation hooks in quick succession only
    /// hits the network for groups whose last refresh aged past the
    /// throttle interval. Pass `force: true` to refresh every group
    /// unconditionally (pull-to-refresh, cold launch).
    @MainActor
    func foregroundRefresh(force: Bool = false) async {
        guard isSignedInProvider() else { return }
        await withTaskGroup(of: Void.self) { tg in
            var inFlight = 0
            for group in groups {
                if inFlight >= 4 { _ = await tg.next() }
                tg.addTask { await self.refresh(groupID: group.id, force: force) }
                inFlight += 1
            }
        }
    }

    /// Pulls the server's group list and merges, then kicks the drainer to
    /// push any accumulated dirty/tombstone entries.
    ///
    /// Order matters: drain FIRST, then list. If we listed first, a group the
    /// user just deleted (whose DELETE hasn't drained yet) would still be in
    /// the server's response and get re-appended below. Drain first so the
    /// server reflects our intent before we ask it.
    ///
    /// Even with that order, the merge below still consults `syncState` for
    /// in-flight tombstones — covers the case where the drain failed (offline,
    /// 5xx) and we shouldn't resurrect.
    /// Called on sign-in and on every scene .active when signed-in.
    func reconcileOnSignIn() async {
        await syncDrainer.kick()    // push pending tombstones/upserts first
        do {
            let serverGroups = try await repository.listShared()
            let tombstones = await syncState.tombstones
            let dirty = await syncState.dirty
            let tombstoneKeys = Set(tombstones.keys)
            let editing = activeEditingEntity
            let serverGroupIDs = Set(serverGroups.map(\.id))
            for server in serverGroups {
                let groupKey = EntityKey.group(server.id)
                // Skip groups the user has locally deleted but whose DELETE
                // hasn't drained yet. Skip dirty groups too — local has
                // unpushed changes that should win until the drainer pushes.
                if tombstones[groupKey] != nil { continue }
                if dirty.contains(groupKey) { continue }
                if let i = groups.firstIndex(where: { $0.id == server.id }) {
                    // Per-entity merge — wholesale replace would clobber
                    // children whose PUTs are still in flight (e.g., the
                    // user just signed in after an anonymous create+expense
                    // session; the group has landed but expenses may be
                    // mid-drain). Mirror refresh()'s merge logic so dirty
                    // children survive.
                    var merged = groups[i]
                    merged.name = server.name
                    merged.emoji = server.emoji
                    merged.currencyCode = server.currencyCode
                    merged.archivedAt = server.archivedAt
                    merged.updatedAt = server.updatedAt
                    merged.version = server.version
                    merged.expenses = mergeChildren(
                        local: groups[i].expenses,
                        server: server.expenses,
                        groupID: server.id, kind: .expense,
                        dirty: dirty, tombstones: tombstoneKeys, editing: editing
                    )
                    let mergedPayments = mergeChildren(
                        local: groups[i].payments ?? [],
                        server: server.payments ?? [],
                        groupID: server.id, kind: .payment,
                        dirty: dirty, tombstones: tombstoneKeys, editing: editing
                    )
                    merged.payments = mergedPayments.isEmpty ? groups[i].payments : mergedPayments
                    let referencedMemberIDs = Self.memberIDsReferenced(
                        expenses: merged.expenses,
                        payments: merged.payments ?? []
                    )
                    merged.members = mergeChildren(
                        local: groups[i].members,
                        server: server.members,
                        groupID: server.id, kind: .member,
                        dirty: dirty, tombstones: tombstoneKeys, editing: editing,
                        preserveIDs: referencedMemberIDs
                    )
                    groups[i] = merged
                } else {
                    groups.append(server)
                }
            }
            // Evict any local synced group the user no longer belongs to:
            //   - omitted from listShared (server hides the group from non-
            //     members once the host kicks them), or
            //   - present but the merge dropped our seat (some server
            //     responses return the group with our membership absent).
            // Skip dirty/tombstoned groups so in-flight local intent isn't
            // clobbered before the drainer settles. Snapshot the IDs first
            // since `evictGroupRemovedByHost` mutates `groups`.
            let localIDs = groups.map(\.id)
            for gid in localIDs {
                guard let g = groups.first(where: { $0.id == gid }) else { continue }
                if !isShared(gid) { continue }
                let key = EntityKey.group(gid)
                if dirty.contains(key) || tombstoneKeys.contains(key) { continue }
                if !serverGroupIDs.contains(gid) || !currentUserStillBelongs(to: g) {
                    await evictGroupRemovedByHost(gid)
                }
            }
            await persist()
        } catch {
            // Network may be flaky; we already kicked the drainer above.
        }
    }

    /// Sign-out cleanup. Drops all in-memory groups and sync state.
    /// Tombstones are kept so the next sign-in doesn't resurrect
    /// deleted groups/entities the server still returns.
    ///
    /// For an explicit "wipe everything" action (Settings → Reset All Data)
    /// see `resetAll()`.
    func dropAll() async {
        // Drain pending tombstones/upserts BEFORE wiping. If the user just
        // deleted a group then immediately signed out, the wipe would race
        // with the in-flight drain — the tombstone gets cleared before the
        // server DELETE lands, and the next sign-in resurrects the group
        // via listShared. drainNow() blocks until pending work is delivered.
        // Offline users still lose pending changes (unavoidable given the
        // "wipe everything" policy).
        await syncDrainer.drainNow()

        // Clear server-bound identity; the user is anonymous again. Local
        // name/emoji stay so the next sign-in can reuse them as a hint.
        if user.serverID != nil { user.serverID = nil }

        groups.removeAll()
        activeEditingEntity = nil
        pendingDeletion = nil
        conflictBanners.removeAll()
        drafts.removeAll()
        await syncState.wipe()
        await persist()
    }

    func dismissConflictBanner(_ id: UUID) {
        conflictBanners.removeAll(where: { $0.id == id })
    }

    // MARK: - Invites

    /// Wraps the optional `anonRegister` closure injected at init. TabKeepApp
    /// (Task 13) wires this to AuthSession.registerAnonymousDevice. No-op when
    /// the closure isn't wired (tests, in-memory factories).
    private func registerAnonymousDeviceIfNeeded() async throws {
        guard let anonRegister else { return }
        try await anonRegister()
    }

    /// Mints an invite for the given group. If the host is anonymous, silently
    /// registers an anonymous device first. Force-pushes the group via
    /// `repository.putGroup` before mint so the server has the row to point
    /// the invite at. On stale-write, adopts the server's metadata locally
    /// and retries the put exactly once. Returns a share-ready URL.
    @MainActor
    func createInvite(for groupID: UUID) async throws -> URL {
        guard let inviteService else {
            throw RepositoryError.unavailable
        }

        // 1. Ensure the device is server-known so the mint call has a bearer.
        if !isSignedInProvider() {
            try await registerAnonymousDeviceIfNeeded()
        }

        // 2. Force-push the group so the server has the row before mint.
        guard let group = groups.first(where: { $0.id == groupID }) else {
            throw RepositoryError.unavailable
        }
        let outcome = try await repository.putGroup(group)
        if case .staleWrite(let serverGroup) = outcome {
            adoptServerGroupMetadata(serverGroup)
            await persist()
            // Re-read the updated local copy and retry once. A second 409 rethrows.
            guard let updated = groups.first(where: { $0.id == groupID }) else {
                throw RepositoryError.unavailable
            }
            _ = try await repository.putGroup(updated)
        }

        // 3. Mint.
        return try await inviteService.mintLink(for: groupID)
    }

    /// Entry point for both cold (deferred-link, post-onboarding tick) and
    /// warm (live tap via onOpenURL) invite-link flows. Previews the token,
    /// then either silent-accepts (cold) or stages `pendingInviteConfirm`
    /// for the warm-tap confirm sheet.
    @MainActor
    func handleIncomingInvite(token: String, isColdPath: Bool) async {
        // Drop concurrent calls. The cold-path (RootTabView .task / scenePhase
        // retry) and warm-path (onOpenURL) can both invoke this in quick
        // succession when a fresh tap lands while a prior deferred-link
        // token is still being processed. Letting both run interleaves
        // their state writes (pendingInviteConfirm, pendingInviteToken,
        // banner) unpredictably.
        guard !inviteProcessingActive else { return }
        inviteProcessingActive = true
        defer { inviteProcessingActive = false }

        guard let inviteService else {
            inviteErrorBanner = InviteErrorBanner(
                message: "Couldn't open invite link. Try again later."
            )
            return
        }

        // Need a server-known device to call accept later. Register
        // anonymously if needed; preview itself is unauth but accept isn't.
        if !isSignedInProvider() {
            do { try await registerAnonymousDeviceIfNeeded() }
            catch {
                inviteErrorBanner = InviteErrorBanner(
                    message: "Couldn't open invite link. Try again later."
                )
                pendingInviteToken = nil
                await persist()
                return
            }
        }

        let preview: InvitePreviewResponse
        do {
            preview = try await inviteService.preview(rawToken: token)
        } catch let err as APIError {
            switch err {
            case .server(let code, _, _, _)
                where code == InviteErrorCode.revoked
                   || code == InviteErrorCode.expired
                   || code == InviteErrorCode.notFound:
                inviteErrorBanner = InviteErrorBanner(
                    message: "This invite link is no longer valid."
                )
                pendingInviteToken = nil
                inviteService.markHandled(token)
                await persist()
                return
            default:
                inviteErrorBanner = InviteErrorBanner(
                    message: "Couldn't open invite link. Try again later."
                )
                // Keep pendingInviteToken so a later foreground retry can
                // pick it up (cold path).
                return
            }
        } catch {
            inviteErrorBanner = InviteErrorBanner(
                message: "Couldn't open invite link. Try again later."
            )
            return
        }

        if isColdPath {
            await finishAcceptingInvite(token: token, preview: preview)
        } else {
            pendingInviteConfirm = PendingInviteConfirm(
                rawToken: token,
                groupID: preview.group.id,
                groupName: preview.group.name,
                groupEmoji: preview.group.emoji,
                memberCount: preview.group.memberCount
            )
        }
    }

    /// Performs the accept HTTP call and adopts the server's group via
    /// `repository.refresh` (which gives us a fully-mapped ExpenseGroup
    /// through the existing DTO→model path — accept's GroupDTO is discarded).
    /// Called by InviteConfirmSheet's Join button (warm) and by
    /// `handleIncomingInvite` directly (cold).
    @MainActor
    func finishAcceptingInvite(token: String, preview: InvitePreviewResponse) async {
        guard let inviteService else {
            inviteErrorBanner = InviteErrorBanner(
                message: "Couldn't open invite link. Try again later."
            )
            return
        }

        // Accept. On failure, surface and bail. If the server
        // signaled the link itself is no longer valid (host revoked, or
        // the link expired between preview and Join, or the token was
        // never real), surface a precise message instead of the generic
        // transport-failure one — re-tapping won't help, so don't tease
        // a retry.
        do {
            _ = try await inviteService.accept(rawToken: token)
        } catch let err as APIError {
            let message: String
            switch err {
            case .server(let code, _, _, _)
                where code == InviteErrorCode.revoked
                   || code == InviteErrorCode.expired
                   || code == InviteErrorCode.notFound:
                message = "This invite link is no longer valid."
                pendingInviteToken = nil
                inviteService.markHandled(token)
            default:
                message = "Couldn't open invite link. Try again later."
            }
            inviteErrorBanner = InviteErrorBanner(message: message)
            await persist()
            return
        } catch {
            inviteErrorBanner = InviteErrorBanner(
                message: "Couldn't open invite link. Try again later."
            )
            return
        }
        // Token is now consumed server-side. Keep the SDK's sticky
        // lastReceivedPayload from re-yielding it on the next foreground.
        inviteService.markHandled(token)

        // Open the eviction grace window for this group. Concurrent GETs
        // (foregroundRefresh, GroupDetailView.task) may still see a stale
        // "no membership" snapshot until the server's accept transaction
        // propagates. See `recentInviteAccepts` and `evictGroupRemovedByHost`.
        //
        // Also prune any timestamps that are older than 2× the grace window —
        // they can't suppress eviction anymore and just accumulate per join.
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.inviteAcceptGracePeriod * 2)
        recentInviteAccepts = recentInviteAccepts.filter { $0.value > cutoff }
        recentInviteAccepts[preview.group.id] = now

        // Re-join clears any stale "You were removed from this group" banner
        // for this group. On scenePhase=.active, foregroundRefresh runs
        // before this code path (see TabKeepApp.swift), so a kicked user
        // tapping a fresh invite gets the banner posted by the listShared
        // eviction *just before* the silent accept un-deletes their seat —
        // the banner survives the successful re-join and looks like a join
        // failure.
        conflictBanners.removeAll {
            if case .removedFromGroup(let gid, _) = $0.kind {
                return gid == preview.group.id
            }
            return false
        }

        // Belt-and-suspenders: a fresh install arriving via an invite link
        // may have raced through onboarding so quickly that the
        // .onChange(of: hasOnboarded) prompt and the deferred-link
        // consumption interleaved. Calling here too is safe — iOS dedupes
        // the system prompt to a no-op the second time. Fire-and-forget;
        // permission errors must never affect invite acceptance.
        if let requestPushPermission { Task { await requestPushPermission() } }

        // Refresh to adopt the canonical group with full child hydration.
        // If refresh fails (transport hiccup) the membership still succeeded
        // server-side; fall back to a minimal placeholder group so the user
        // gets navigated and lastJoinedGroupID fires. The next foreground
        // tick (reconcileOnSignIn or refresh) will hydrate the full group.
        do {
            let serverGroup = try await repository.refresh(groupID: preview.group.id)
            if let i = groups.firstIndex(where: { $0.id == serverGroup.id }) {
                groups[i] = serverGroup
            } else {
                groups.append(serverGroup)
            }
        } catch {
            // Accept succeeded; refresh failed. Insert a minimal placeholder
            // so the user sees the group title in the list and gets navigated.
            // Children (expenses/payments) will hydrate on next refresh tick.
            if !groups.contains(where: { $0.id == preview.group.id }) {
                let placeholder = ExpenseGroup(
                    id: preview.group.id,
                    name: preview.group.name,
                    emoji: preview.group.emoji,
                    currencyCode: defaultCurrencyCode,
                    members: [],
                    expenses: [],
                    createdAt: Date()
                )
                groups.append(placeholder)
            }
            // Mark the group dirty so the drainer / next refresh picks it up.
            await syncState.markDirty(.group(preview.group.id))
            Task { await syncDrainer.kick() }
        }

        // Land in the joined group. Ghost memberships no longer exist —
        // the Rails migration that accompanied this build swept all
        // legacy rows.
        pendingInviteToken = nil
        pendingInviteConfirm = nil
        lastJoinedGroupID = preview.group.id

        // Retroactively add the just-joined user to existing expenses that
        // haven't been explicitly settled. No-op when the refresh fell back
        // to the placeholder group (no expenses to inspect) or the server
        // hasn't yet stamped this user's membership.
        await backfillSelfIntoExistingExpenses(in: preview.group.id)

        await persist()
    }

    /// Runs once at the end of an invite accept: walks the group's expenses
    /// and adds the just-joined user as a participant to every expense that
    /// is not deleted, not custom-share, not already including them, and not
    /// settled — where "settled" means either explicitly linked from a
    /// payment's `expenseIDs`, or covered by a general-settle payment (no
    /// `expenseIDs`) dated on or after the expense. Marks each touched
    /// expense dirty so the drainer pushes the change, and sets
    /// `pendingBackfill` to drive the snackbar.
    private func backfillSelfIntoExistingExpenses(in groupID: UUID) async {
        guard let group = groups.first(where: { $0.id == groupID }),
              let newMember = userMember(in: group) else { return }

        let nonDeletedPayments = (group.payments ?? []).filter { $0.deletedAt == nil }

        let explicitlySettledIDs: Set<UUID> = Set(
            nonDeletedPayments.flatMap { $0.expenseIDs ?? [] }
        )
        let generalSettlePayments = nonDeletedPayments.filter {
            ($0.expenseIDs ?? []).isEmpty
        }

        // Day-grain comparison: a payment dated May 10 covers an expense
        // dated May 10 regardless of time-of-day on either side. Comparing
        // raw Date instants caused same-day misses when the payment picker
        // and expense picker resolved to different times.
        let calendar = Calendar.current
        func isSettledForBackfill(_ e: Expense) -> Bool {
            if explicitlySettledIDs.contains(e.id) { return true }
            return generalSettlePayments.contains {
                calendar.compare($0.date, to: e.date, toGranularity: .day) != .orderedAscending
            }
        }

        var touchedExpenseIDs: [UUID] = []
        var skippedCustomShareCount = 0
        var skippedSettledCount = 0

        // Settled check runs before custom-share so an expense that is both
        // settled and custom-share counts only in the settled bucket — the
        // two skip counters stay mutually exclusive per expense.
        for e in group.expenses {
            if e.deletedAt != nil { continue }
            if e.participantIDs.contains(newMember.id) { continue }
            if isSettledForBackfill(e) {
                skippedSettledCount += 1
                continue
            }
            if let shares = e.shares, !shares.isEmpty {
                skippedCustomShareCount += 1
                continue
            }
            touchedExpenseIDs.append(e.id)
        }

        guard !touchedExpenseIDs.isEmpty else {
            // Suppress the banner when nothing was actually touched — even
            // if custom-share expenses existed. Cleaner UX.
            return
        }

        var didMutate = false
        try? mutateGroupSync(groupID) { g in
            for id in touchedExpenseIDs {
                guard let i = g.expenses.firstIndex(where: { $0.id == id }) else { continue }
                g.expenses[i].participantIDs.append(newMember.id)
                didMutate = true
            }
        }
        // `mutateGroupSync` throws (e.g., AppStoreError.groupArchived) are swallowed
        // by `try?`. If nothing was mutated — either the throw fired or every
        // firstIndex lookup missed — skip the sync work and don't surface a
        // misleading "Added to N expenses" banner.
        guard didMutate else { return }

        for id in touchedExpenseIDs {
            await syncState.markDirty(.expense(id, in: groupID))
        }
        await persist()
        Task { await syncDrainer.kick() }

        pendingBackfill = PendingBackfill(
            id: UUID(),
            groupID: groupID,
            memberID: newMember.id,
            expenseIDs: touchedExpenseIDs,
            skippedCustomShareCount: skippedCustomShareCount,
            skippedSettledCount: skippedSettledCount
        )
    }

    /// Driver callback: append a banner from a replay outcome.
    func appendConflictBanner(_ banner: ConflictBanner) {
        conflictBanners.append(banner)
    }

    // MARK: - Derived

    func balances(forGroup groupID: UUID) -> [MemberBalance] {
        guard let g = group(id: groupID) else { return [] }
        return BalanceCalculator.balances(for: g)
    }

    func settlements(forGroup groupID: UUID) -> [Settlement] {
        simplifier.settlements(from: balances(forGroup: groupID))
    }

    func pendingRatesCount(forGroup groupID: UUID) -> Int {
        group(id: groupID)?.expenses.filter(\.ratePending).count ?? 0
    }

    // MARK: - FX retry

    func retryPendingRates() async {
        if isRetryingPendingRates { return }
        isRetryingPendingRates = true
        defer { isRetryingPendingRates = false }

        var dirtiedExpenseKeys: [EntityKey] = []
        for gi in groups.indices {
            let groupID = groups[gi].id
            let groupCurrency = groups[gi].currencyCode
            for ei in groups[gi].expenses.indices where groups[gi].expenses[ei].ratePending {
                let expense = groups[gi].expenses[ei]
                if expense.currencyCode == groupCurrency {
                    groups[gi].expenses[ei].exchangeRate = 1
                    groups[gi].expenses[ei].ratePending = false
                    dirtiedExpenseKeys.append(.expense(expense.id, in: groupID))
                    continue
                }
                do {
                    let rate = try await fxService.rate(from: expense.currencyCode, to: groupCurrency, on: expense.date)
                    groups[gi].expenses[ei].exchangeRate = rate
                    groups[gi].expenses[ei].ratePending = false
                    dirtiedExpenseKeys.append(.expense(expense.id, in: groupID))
                } catch {
                    // still offline / API trouble — leave pending
                }
            }
        }
        if !dirtiedExpenseKeys.isEmpty {
            for key in dirtiedExpenseKeys {
                await syncState.markDirty(key)
            }
            await persist()
            Task { await syncDrainer.kick() }
        }
    }

    // MARK: - Helpers

    private func fetchRate(from fromCode: String, to toCode: String, on date: Date) async -> (rate: Decimal, pending: Bool) {
        if fromCode == toCode { return (1, false) }
        do {
            let rate = try await fxService.rate(from: fromCode, to: toCode, on: date)
            return (rate, false)
        } catch {
            return (1, true)
        }
    }

    func convertToDefault(
        groupAmount: Decimal,
        groupCurrency: String,
        on date: Date
    ) async -> (value: Decimal, pending: Bool) {
        if groupCurrency == defaultCurrencyCode {
            return (groupAmount, false)
        }
        do {
            let rate = try await fxService.rate(from: groupCurrency, to: defaultCurrencyCode, on: date)
            return (groupAmount * rate, false)
        } catch {
            return (0, true)
        }
    }

    /// Synchronous mutate-group helper. Only updates in-memory state — the
    /// caller is responsible for calling `await persist()` afterwards.
    private func mutateGroupSync(
        _ id: UUID,
        allowArchived: Bool = false,
        _ edit: (inout ExpenseGroup) throws -> Void
    ) throws {
        guard let i = groups.firstIndex(where: { $0.id == id }) else {
            throw AppStoreError.groupNotFound
        }
        // Archived groups are read-only. The archive/unarchive toggles
        // themselves pass `allowArchived: true` to flip the flag.
        if !allowArchived && groups[i].archivedAt != nil {
            throw AppStoreError.groupArchived
        }
        var g = groups[i]
        try edit(&g)
        groups[i] = g
    }

    /// Pushes the group's current metadata (name, emoji, currency,
    /// archivedAt) to the server. Shared by `updateGroup`, `archiveGroup`,
    /// and `unarchiveGroup` — all three change a metadata subset but the
    /// server's PATCH endpoint takes the full snapshot. The body uses
    /// `group.updatedAt` as the optimistic-concurrency precondition the
    /// server compares against, so do **not** mutate `updatedAt` locally
    /// before calling this — the server has never seen a local-clock
    /// `Date()` and would 409.
    private func syncGroupMetadata(id: UUID) async throws {
        await syncState.markDirty(.group(id))
        Task { await syncDrainer.kick() }
    }

    private func persist() async {
        let state = PersistedState(
            groups: groups,
            defaultCurrencyCode: defaultCurrencyCode,
            activityLog: activityLog,
            pendingInviteToken: pendingInviteToken
        )
        do {
            try await repository.saveLocal(state)
        } catch {
            persistErrorLog.error("persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Normalizes and validates multi-payer payment entries. Returns nil
    /// when no payments are provided (single-payer mode); returns a
    /// non-empty array when multi-payer is in effect. Drops zero-amount
    /// entries — the form may emit them for unchecked rows.
    ///
    /// Throws:
    /// - `.memberNotInGroup` if any payment references a non-member
    /// - `.splitAmountMismatch` if the sum is off by more than $0.01
    /// Member ids referenced by any of the given expenses / payments.
    /// Used by the merge to keep a still-needed member from being dropped
    /// when the server transiently omits it (e.g. a ghost membership the
    /// server still lists but a stale read skipped). The member's local
    /// copy stays in place; the next refresh that does include them will
    /// overwrite with the server's canonical row.
    private static func memberIDsReferenced(
        expenses: [Expense],
        payments: [Payment]
    ) -> Set<UUID> {
        var refs: Set<UUID> = []
        for e in expenses where e.deletedAt == nil {
            refs.insert(e.payerID)
            refs.formUnion(e.participantIDs)
            if let shares = e.shares { refs.formUnion(shares.map(\.memberID)) }
            if let pmts = e.payments { refs.formUnion(pmts.map(\.memberID)) }
        }
        for p in payments where p.deletedAt == nil {
            refs.insert(p.fromMemberID)
            refs.insert(p.toMemberID)
        }
        return refs
    }

    private static func validatePayments(
        _ payments: [ExpensePayment]?,
        amount: Decimal,
        memberIDs: Set<UUID>
    ) throws -> [ExpensePayment]? {
        guard let payments, !payments.isEmpty else { return nil }
        let nonZero = payments.filter { $0.amount > 0 }
        guard !nonZero.isEmpty else { return nil }
        for p in nonZero where !memberIDs.contains(p.memberID) {
            throw AppStoreError.memberNotInGroup
        }
        let sum = nonZero.reduce(Decimal(0)) { $0 + $1.amount }
        if abs(sum - amount) > Decimal(0.01) {
            throw AppStoreError.splitAmountMismatch
        }
        return nonZero
    }

    private static func describeChanges(
        before: Expense,
        after: Expense,
        members: [Member]
    ) -> [String] {
        var changes: [String] = []

        if before.description != after.description {
            let bd = before.description.isEmpty ? "—" : before.description
            let ad = after.description.isEmpty ? "—" : after.description
            changes.append("description: \"\(bd)\" → \"\(ad)\"")
        }
        if before.amount != after.amount || before.currencyCode != after.currencyCode {
            let fmtBefore: (Decimal) -> String = { $0.formatted(.currency(code: before.currencyCode)) }
            let fmtAfter: (Decimal) -> String = { $0.formatted(.currency(code: after.currencyCode)) }
            changes.append("amount: \(fmtBefore(before.amount)) → \(fmtAfter(after.amount))")
        }
        if before.currencyCode != after.currencyCode {
            changes.append("currency: \(before.currencyCode) → \(after.currencyCode)")
        }
        if before.date != after.date {
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .short
            changes.append("date: \(df.string(from: before.date)) → \(df.string(from: after.date))")
        }
        if before.category != after.category {
            changes.append("category: \(before.category.displayName) → \(after.category.displayName)")
        }
        if before.payerID != after.payerID {
            let name: (UUID) -> String = { id in
                members.first(where: { $0.id == id })?.name ?? "Unknown"
            }
            changes.append("paid by: \(name(before.payerID)) → \(name(after.payerID))")
        }
        if Set(before.participantIDs) != Set(after.participantIDs) {
            let b = before.participantIDs.count
            let a = after.participantIDs.count
            if b != a {
                changes.append("split: \(b) → \(a) members")
            } else {
                changes.append("split: members changed")
            }
        }
        let beforeReceiptIDs = before.receipts.map(\.id)
        let afterReceiptIDs = after.receipts.map(\.id)
        if beforeReceiptIDs != afterReceiptIDs {
            let b = beforeReceiptIDs.count
            let a = afterReceiptIDs.count
            if b != a {
                changes.append("receipts: \(b) → \(a)")
            } else {
                changes.append("receipts changed")
            }
        }
        return changes
    }

    /// Mirrors `describeChanges(before:after:members:)` for payments.
    /// Compares `from`, `to`, `amount`, `date`, and `note`. Amount is
    /// always in the group's current currency (no per-payment currencyCode).
    private static func describePaymentChanges(
        before: Payment,
        after: Payment,
        groupCurrency: String,
        members: [Member]
    ) -> [String] {
        var changes: [String] = []
        let name: (UUID) -> String = { id in
            members.first(where: { $0.id == id })?.name ?? "Unknown"
        }
        if before.fromMemberID != after.fromMemberID {
            changes.append("from: \(name(before.fromMemberID)) → \(name(after.fromMemberID))")
        }
        if before.toMemberID != after.toMemberID {
            changes.append("to: \(name(before.toMemberID)) → \(name(after.toMemberID))")
        }
        if before.amount != after.amount {
            let fmt: (Decimal) -> String = { $0.formatted(.currency(code: groupCurrency)) }
            changes.append("amount: \(fmt(before.amount)) → \(fmt(after.amount))")
        }
        if before.date != after.date {
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .short
            changes.append("date: \(df.string(from: before.date)) → \(df.string(from: after.date))")
        }
        if (before.note ?? "") != (after.note ?? "") {
            let bn = (before.note?.isEmpty == false) ? "\"\(before.note!)\"" : "—"
            let an = (after.note?.isEmpty == false) ? "\"\(after.note!)\"" : "—"
            changes.append("note: \(bn) → \(an)")
        }
        return changes
    }
}

// MARK: - User-aware balance helpers

extension AppStore {
    /// The Member representing the device owner inside a group.
    /// Identification preference (most → least specific):
    ///   1. server-assigned `member.userID` matches `user.serverID` (set
    ///      via the membership upsert's `is_self: true`). Survives renames.
    ///   2. fallback to legacy name-match for groups created before the
    ///      `userID` field existed (or before sign-in).
    func userMember(in group: ExpenseGroup) -> Member? {
        if let serverID = user.serverID,
           let m = group.members.first(where: { $0.userID == serverID }) {
            return m
        }
        guard user.hasName else { return nil }
        let key = user.matchKey
        return group.members.first { $0.name.lowercased() == key }
    }

    /// User's net balance in a group, expressed in the group's currency,
    /// or nil if the user isn't a member of the group.
    func userBalance(in group: ExpenseGroup) -> Decimal? {
        guard let member = userMember(in: group) else { return nil }
        return BalanceCalculator
            .balances(for: group)
            .first { $0.memberID == member.id }?
            .netAmount
    }

    /// Async cross-currency snapshot for the Groups list hero card. Converts
    /// each active group's user balance into `defaultCurrencyCode` via
    /// `FXService` (cached) and aggregates owed-to-user vs user-owes totals.
    func heroSnapshot(date: Date = Date()) async -> HeroSnapshot {
        var owed = Decimal(0)
        var owes = Decimal(0)
        var pending = 0
        var unsettled = 0
        let active = activeGroups
        for group in active {
            if !settlements(forGroup: group.id).isEmpty {
                unsettled += 1
            }
            guard let bal = userBalance(in: group), bal != 0 else { continue }
            let result = await convertToDefault(
                groupAmount: bal,
                groupCurrency: group.currencyCode,
                on: date
            )
            if result.pending { pending += 1 }
            if result.value > 0 {
                owed += result.value
            } else if result.value < 0 {
                owes += -result.value
            }
        }
        return HeroSnapshot(
            netInDefault: owed - owes,
            owedToUser: owed,
            userOwes: owes,
            groupCount: active.count,
            unsettledCount: unsettled,
            pendingCount: pending,
            displayCurrency: defaultCurrencyCode
        )
    }
}

struct HeroSnapshot: Equatable {
    var netInDefault: Decimal
    var owedToUser: Decimal
    var userOwes: Decimal
    var groupCount: Int
    var unsettledCount: Int
    var pendingCount: Int
    var displayCurrency: String

    static let empty = HeroSnapshot(
        netInDefault: 0,
        owedToUser: 0,
        userOwes: 0,
        groupCount: 0,
        unsettledCount: 0,
        pendingCount: 0,
        displayCurrency: "USD"
    )
}

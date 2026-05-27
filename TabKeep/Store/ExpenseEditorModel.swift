// SplitBill/Store/ExpenseEditorModel.swift
import SwiftUI
import Observation

@Observable
final class ExpenseEditorModel {
    enum Mode: Equatable {
        case create(groupID: UUID)
        case edit(groupID: UUID, expenseID: UUID)
    }

    let mode: Mode

    // MARK: - Form fields (bound via @Bindable)

    var amountText: String = "0"
    var description: String = ""
    var payerID: UUID?
    var participantIDs: Set<UUID> = []
    var date: Date = Date()
    var category: ExpenseCategory = .other
    var currencyCode: String = "USD"
    var pendingReceipts: [PendingReceipt] = []
    var splitIsValid: Bool = true
    var shares: [ExpenseShare]?
    /// When non-nil, the expense has multiple payers and the sum of
    /// `payments` equals `amount`. When nil, the expense is single-payer
    /// (`payerID` paid the full amount — the legacy default).
    var payments: [ExpensePayment]?
    /// "amount" / "percent" / nil. Set by the form when the user chooses a
    /// split mode; passed through to the persisted Expense at save time.
    var splitKind: String?

    // MARK: - Read-only state

    private(set) var isSaving: Bool = false
    private(set) var isRestoringDraft: Bool = false
    private(set) var initialShares: [ExpenseShare]?
    private(set) var initialPayments: [ExpensePayment]?
    /// User-facing error message from the last save attempt. Cleared when
    /// the alert is dismissed. nil while no error is pending. Read by
    /// EditExpenseView to drive the "Couldn't save" alert — earlier the
    /// catch block in ExpenseEditor swallowed errors silently and a
    /// failing Save just felt unresponsive.
    var lastSaveError: String?
    /// The persisted split kind ("amount" / "percent") if the existing
    /// expense was authored with a custom split, used by the form's
    /// onAppear to choose which split UI to seed. nil for new expenses or
    /// legacy equal-split.
    private(set) var initialSplitKind: String?

    // MARK: - Internals

    private let store: AppStore
    private let receiptStore: ReceiptStore
    private var didPrepare: Bool = false
    private var initialOriginalReceiptIDs: Set<UUID> = []
    private var initialSnapshot: Snapshot?

    private struct Snapshot: Equatable {
        let amountText: String
        let description: String
        let payerID: UUID?
        let participantIDs: Set<UUID>
        let date: Date
        let category: ExpenseCategory
        let currencyCode: String
        let receiptIDs: [UUID]
    }

    init(mode: Mode, store: AppStore, receiptStore: ReceiptStore = .default()) {
        self.mode = mode
        self.store = store
        self.receiptStore = receiptStore
    }

    // MARK: - Derived

    var groupID: UUID {
        switch mode {
        case .create(let id):       return id
        case .edit(let id, _):      return id
        }
    }

    var group: ExpenseGroup? { store.group(id: groupID) }
    var accent: Color { AppTheme.accent }
    var amount: Decimal { Decimal(string: amountText) ?? 0 }
    /// Forwarded to `[Member].pickable(currentUserServerID:)` so the
    /// payer/participant pickers can filter out ghost members. nil when the
    /// local user is anonymous — pickable() keeps unbound seats in that case
    /// because the user's own seat may legitimately be unbound.
    var currentUserServerID: UUID? { store.user.serverID }

    var canSave: Bool {
        if isReadOnly { return false }
        let baseValid = amount > 0
            && !description.trimmingCharacters(in: .whitespaces).isEmpty
            && payerID != nil
            && !participantIDs.isEmpty
            && splitIsValid
        guard baseValid else { return false }
        // In edit mode, require the user to have actually changed something
        // before Save lights up — prevents pointless re-saves.
        if isEditing { return isDirty }
        return true
    }

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// True when the editor should display the existing expense without
    /// allowing changes. Two triggers:
    ///   - The group is archived (any member can still look but not touch).
    ///   - The current user lacks the server's `can_edit?` permission for
    ///     this expense (not host, not payer, not a split participant).
    ///     Hiding the affordance here prevents an unauthorized round-trip
    ///     that would 403 and surface as a permission-denied banner.
    /// Create-mode is never read-only (membership in the group is the
    /// server's only requirement for creating; we don't have the
    /// not-yet-persisted Expense to evaluate against the edit rule).
    /// Why the editor is locked, if it is. nil = editable.
    enum ReadOnlyReason {
        /// The group itself is archived — anyone can look but not touch.
        case archived
        /// The current user lacks `can_edit?` server permission for this
        /// expense (not host, not payer, not in the split). Distinct from
        /// `.archived` so the banner can explain the right reason — telling
        /// a new member "the group is archived" when they simply weren't in
        /// the expense's split is misleading.
        case noPermission
    }

    var readOnlyReason: ReadOnlyReason? {
        if group?.archivedAt != nil { return .archived }
        if case .edit(let gID, let eID) = mode,
           let g = store.group(id: gID),
           let e = g.expenses.first(where: { $0.id == eID }),
           !store.canEditExpense(e, in: g) {
            return .noPermission
        }
        return nil
    }

    var isReadOnly: Bool { readOnlyReason != nil }

    var isReady: Bool {
        switch mode {
        case .create:                       return true
        case .edit(_, let expenseID):       return existingExpense(id: expenseID) != nil
        }
    }

    var isDirty: Bool {
        guard let initial = initialSnapshot else { return false }
        if initial != currentSnapshot { return true }
        // shares + payments aren't in Snapshot (would require capturing
        // them before the form's onAppear runs, which is awkward). Compare
        // current vs. initial directly. Sort by memberID so order differences
        // don't trip the diff.
        let curShares = (shares ?? []).sorted { $0.memberID.uuidString < $1.memberID.uuidString }
        let origShares = (initialShares ?? []).sorted { $0.memberID.uuidString < $1.memberID.uuidString }
        if curShares != origShares { return true }
        let curPayments = (payments ?? []).sorted { $0.memberID.uuidString < $1.memberID.uuidString }
        let origPayments = (initialPayments ?? []).sorted { $0.memberID.uuidString < $1.memberID.uuidString }
        return curPayments != origPayments
    }

    private var currentSnapshot: Snapshot {
        Snapshot(
            amountText: amountText,
            description: description,
            payerID: payerID,
            participantIDs: participantIDs,
            date: date,
            category: category,
            currencyCode: currencyCode,
            receiptIDs: pendingReceipts.map(\.id)
        )
    }

    private func existingExpense(id: UUID) -> Expense? {
        group?.expenses.first { $0.id == id }
    }

    // MARK: - Lifecycle

    func prepareIfNeeded() {
        guard !didPrepare else { return }
        switch mode {
        case .create:
            prefillDefaults()
            didPrepare = true
        case .edit(_, let expenseID):
            // Only flip didPrepare when the prefill actually populated.
            // A push-tap can navigate here before the silent-companion
            // sync has landed the referenced expense; we want the next
            // call (triggered by ExpenseEditor.onAppear when isReady
            // flips true) to retry rather than leave the editor with
            // blank fields.
            if prefillFromExisting(expenseID: expenseID) {
                didPrepare = true
            }
        }
    }

    private func prefillDefaults() {
        guard let g = group else { return }
        if payerID == nil {
            payerID = userMember(in: g)?.id ?? g.members.first?.id
        }
        if participantIDs.isEmpty {
            participantIDs = Set(g.members.map(\.id))
        }
        // Always default to the group's currency on a new expense, so the
        // modal opens in sync with the group rather than the model's "USD"
        // initial value. Falls back to USD only if the group's currency
        // somehow isn't supported.
        currencyCode = SupportedCurrencies.isSupported(g.currencyCode) ? g.currencyCode : "USD"
    }

    @discardableResult
    private func prefillFromExisting(expenseID: UUID) -> Bool {
        guard let e = existingExpense(id: expenseID) else { return false }
        amountText = NSDecimalNumber(decimal: e.amount).stringValue
        description = e.description
        payerID = e.payerID
        participantIDs = Set(e.participantIDs)
        date = e.date
        category = e.category
        currencyCode = SupportedCurrencies.isSupported(e.currencyCode)
            ? e.currencyCode
            : (group?.currencyCode ?? "USD")
        pendingReceipts = e.receipts.map(PendingReceipt.existing)
        initialShares = e.shares
        initialPayments = e.payments
        payments = e.payments
        initialSplitKind = e.splitKind
        initialOriginalReceiptIDs = Set(e.receipts.map(\.id))

        // Overlay the rejected draft if one exists for this entity.
        let key = EntityKey.expense(expenseID, in: groupID)
        if let draft = store.drafts[key],
           case .upsert(let payload) = draft.kind {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let drafted = try? dec.decode(Expense.self, from: payload) {
                amountText = NSDecimalNumber(decimal: drafted.amount).stringValue
                description = drafted.description
                payerID = drafted.payerID
                participantIDs = Set(drafted.participantIDs)
                date = drafted.date
                category = drafted.category
                if SupportedCurrencies.isSupported(drafted.currencyCode) {
                    currencyCode = drafted.currencyCode
                }
                // Don't overlay receipts — the draft was captured before receipts
                // were finalised on disk; respect the local copy.
                initialShares = drafted.shares
                isRestoringDraft = true
            }
        }

        initialSnapshot = currentSnapshot
        return true
    }

    private func userMember(in group: ExpenseGroup) -> Member? {
        guard store.user.hasName else { return nil }
        return group.members.first {
            $0.name.trimmingCharacters(in: .whitespaces).lowercased() == store.user.matchKey
        }
    }

    // MARK: - Save

    @MainActor
    func save() async throws {
        guard let payerID else { return }
        isSaving = true
        lastSaveError = nil
        defer { isSaving = false }

        let finalReceipts = persistPendingReceipts()
        do {
            switch mode {
            case .create(let groupID):
                _ = try await store.addExpense(
                    toGroup: groupID,
                    payerID: payerID,
                    amount: amount,
                    currencyCode: currencyCode,
                    description: description,
                    date: date,
                    participantIDs: Array(participantIDs),
                    category: category,
                    receipts: finalReceipts,
                    shares: shares,
                    payments: payments,
                    splitKind: splitKind
                )
            case .edit(let groupID, let expenseID):
                cleanUpRemovedReceipts(keeping: Set(finalReceipts.map(\.id)))
                try await store.editExpense(
                    id: expenseID,
                    inGroup: groupID,
                    payerID: payerID,
                    amount: amount,
                    currencyCode: currencyCode,
                    description: description,
                    date: date,
                    participantIDs: Array(participantIDs),
                    category: category,
                    receipts: finalReceipts,
                    shares: shares,
                    payments: payments,
                    splitKind: splitKind
                )
                if isRestoringDraft {
                    let key = EntityKey.expense(expenseID, in: groupID)
                    store.discardDraft(key)
                    isRestoringDraft = false
                }
            }
            Haptics.success()
        } catch {
            Haptics.error()
            lastSaveError = Self.userMessage(for: error)
            throw error
        }
    }

    private static func userMessage(for error: Error) -> String {
        if let e = error as? AppStoreError {
            switch e {
            case .memberNotInGroup:
                return "One of the participants is no longer in this group. Pull to refresh and try again."
            case .splitAmountMismatch:
                return "The split amounts don't add up to the total."
            case .unsupportedCurrency:
                return "That currency isn't supported."
            case .invalidExpense:
                return "Amount must be greater than zero."
            case .groupNotFound, .expenseNotFound:
                return "This expense is no longer available. Pull to refresh."
            case .forbidden:
                return "You don't have permission to edit this expense."
            case .groupArchived:
                return "This group is archived. Unarchive it to edit."
            default:
                return "Something went wrong. Please try again."
            }
        }
        return error.localizedDescription
    }

    private func persistPendingReceipts() -> [ReceiptAttachment] {
        var result: [ReceiptAttachment] = []
        for pending in pendingReceipts {
            switch pending {
            case .existing(let r):
                result.append(r)
            case .new(let id, let data):
                do {
                    try receiptStore.writeJPEG(data, id: id)
                    result.append(ReceiptAttachment(
                        id: id,
                        createdAt: Date(),
                        contentType: "image/jpeg",
                        byteSize: Int64(data.count),
                        uploaderUserID: nil
                    ))
                } catch {
                    continue
                }
            }
        }
        return result
    }

    private func cleanUpRemovedReceipts(keeping keptIDs: Set<UUID>) {
        let removed = initialOriginalReceiptIDs.subtracting(keptIDs)
        for id in removed {
            receiptStore.delete(id: id)
        }
    }

    // MARK: - Delete

    func beginDelete() async throws {
        guard case .edit(let groupID, let expenseID) = mode else { return }
        try await store.beginDeleteExpense(id: expenseID, inGroup: groupID)
    }
}

import Foundation

enum ReceiptUploadStep: String, Codable, Hashable, Sendable {
    case metadataPending     // POST /expenses/:id/receipts not yet acknowledged
    case bytesPending        // S3 PUT not yet successful
    case finalizePending     // POST /receipts/:id/finalize not yet acknowledged
}

private struct SyncStateOnDisk: Codable {
    var dirty: [EntityKey]
    var tombstones: [TombstoneEntry]
    var drafts: [DraftEntry]
    var receiptSteps: [ReceiptStepEntry]?

    struct TombstoneEntry: Codable, Hashable {
        let key: EntityKey
        let version: Int
    }
    struct DraftEntry: Codable, Hashable {
        let key: EntityKey
        let draft: RejectedDraft
    }
    struct ReceiptStepEntry: Codable, Hashable {
        let id: UUID
        let step: ReceiptUploadStep
    }
}

actor SyncState {
    static func defaultURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("sync_state.json")
    }

    enum Pending: Equatable {
        case upsert(EntityKey)
        case delete(EntityKey, version: Int)

        var key: EntityKey {
            switch self {
            case .upsert(let k):    return k
            case .delete(let k, _): return k
            }
        }

        var isDelete: Bool {
            if case .delete = self { return true }
            return false
        }
    }

    private let fileURL: URL
    private(set) var dirty: Set<EntityKey> = []
    private(set) var tombstones: [EntityKey: Int] = [:]
    private(set) var drafts: [EntityKey: RejectedDraft] = [:]
    private(set) var receiptSteps: [UUID: ReceiptUploadStep] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
        // Inline the disk read instead of calling self.load() — actor
        // isolation is special inside init (no caller can observe the
        // actor yet, so writing to isolated state is safe) but calling a
        // self-method from init crosses the isolation boundary under
        // strict concurrency. The body below is what load() does.
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(SyncStateOnDisk.self, from: data) else { return }
        self.dirty = Set(decoded.dirty)
        self.tombstones = Dictionary(uniqueKeysWithValues: decoded.tombstones.map { ($0.key, $0.version) })
        self.drafts = Dictionary(uniqueKeysWithValues: decoded.drafts.map { ($0.key, $0.draft) })
        self.receiptSteps = Dictionary(
            uniqueKeysWithValues: (decoded.receiptSteps ?? []).map { ($0.id, $0.step) }
        )
    }

    // MARK: - Reads

    func isDirty(_ k: EntityKey) -> Bool { dirty.contains(k) }
    func isTombstone(_ k: EntityKey) -> Bool { tombstones[k] != nil }
    func draft(for k: EntityKey) -> RejectedDraft? { drafts[k] }
    func allDrafts() -> [EntityKey: RejectedDraft] { drafts }

    func receiptStep(for id: UUID) -> ReceiptUploadStep {
        receiptSteps[id] ?? .metadataPending
    }

    /// Returns the next pending entry. Ordering rules:
    /// 1. Groups first (they must exist server-side before any child).
    /// 2. Members second (expenses/payments reference membership_ids
    ///    via FKs server-side; pushing those before the members exist
    ///    causes validation 422s, which the drainer's generic catch
    ///    clears as conflicts — losing the user's data).
    /// 3. Expenses/payments before receipts.
    /// 4. Receipts last on upserts (parent expense must exist first).
    /// Tombstones use the inverse safe order: receipts first (children
    /// before parents), then payments/expenses → members → groups.
    func nextPending() -> Pending? {
        // Upserts: parents before children.
        for k in dirty where k.kind == .group { return .upsert(k) }
        for k in dirty where k.kind == .member { return .upsert(k) }
        for k in dirty where k.kind == .expense { return .upsert(k) }
        for k in dirty where k.kind == .payment { return .upsert(k) }
        for k in dirty where k.kind == .receipt { return .upsert(k) }
        // Tombstones: children before parents.
        for (k, v) in tombstones where k.kind == .receipt { return .delete(k, version: v) }
        for (k, v) in tombstones where k.kind == .payment { return .delete(k, version: v) }
        for (k, v) in tombstones where k.kind == .expense { return .delete(k, version: v) }
        for (k, v) in tombstones where k.kind == .member { return .delete(k, version: v) }
        for (k, v) in tombstones where k.kind == .group { return .delete(k, version: v) }
        return nil
    }

    // MARK: - Mutations

    func markDirty(_ k: EntityKey) {
        tombstones.removeValue(forKey: k)
        dirty.insert(k)
        persist()
    }

    func markTombstone(_ k: EntityKey, lastKnownVersion: Int) {
        dirty.remove(k)
        tombstones[k] = lastKnownVersion
        persist()
    }

    func clear(_ k: EntityKey) {
        dirty.remove(k)
        tombstones.removeValue(forKey: k)
        if k.kind == .receipt {
            receiptSteps.removeValue(forKey: k.id)
        }
        persist()
    }

    func recordRejected(_ k: EntityKey, _ d: RejectedDraft) {
        drafts[k] = d
        persist()
    }

    func discardDraft(_ k: EntityKey) {
        drafts.removeValue(forKey: k)
        persist()
    }

    func setReceiptStep(_ step: ReceiptUploadStep, for id: UUID) {
        receiptSteps[id] = step
        persist()
    }

    func clearReceiptStep(for id: UUID) {
        receiptSteps.removeValue(forKey: id)
        persist()
    }

    func wipe() {
        dirty.removeAll()
        tombstones.removeAll()
        drafts.removeAll()
        receiptSteps.removeAll()
        persist()
    }

    /// Drops every dirty / tombstone / draft entry whose `EntityKey.groupID`
    /// matches. Used when a group is evicted, left, or deleted — without
    /// this, rejected drafts and stale tombstones for the group's children
    /// linger forever (or worse: re-attach to fresh entities of the same
    /// kind on rejoin).
    func clearAllForGroup(_ groupID: UUID) {
        let droppedReceiptIDs: Set<UUID> = Set(
            dirty.filter { $0.groupID == groupID && $0.kind == .receipt }.map(\.id)
        ).union(
            tombstones.keys.filter { $0.groupID == groupID && $0.kind == .receipt }.map(\.id)
        )
        dirty = dirty.filter { $0.groupID != groupID }
        tombstones = tombstones.filter { $0.key.groupID != groupID }
        drafts = drafts.filter { $0.key.groupID != groupID }
        for id in droppedReceiptIDs { receiptSteps.removeValue(forKey: id) }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let snapshot = SyncStateOnDisk(
            dirty: Array(dirty),
            tombstones: tombstones.map { SyncStateOnDisk.TombstoneEntry(key: $0.key, version: $0.value) },
            drafts: drafts.map { SyncStateOnDisk.DraftEntry(key: $0.key, draft: $0.value) },
            receiptSteps: receiptSteps.map { SyncStateOnDisk.ReceiptStepEntry(id: $0.key, step: $0.value) }
        )
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("SyncState persist failed: \(error)")
        }
    }
}

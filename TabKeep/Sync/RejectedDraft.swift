import Foundation

struct RejectedDraft: Codable, Hashable, Sendable {
    let entityKey: EntityKey
    let kind: Kind
    let rejectedAt: Date
    let serverVersionAtReject: Int

    enum Kind: Codable, Hashable, Sendable {
        case upsert(payload: Data)
        case tombstone
    }

    init(upsertOf entityKey: EntityKey, payload: Data, serverVersion: Int, at: Date = Date()) {
        self.entityKey = entityKey
        self.kind = .upsert(payload: payload)
        self.rejectedAt = at
        self.serverVersionAtReject = serverVersion
    }

    init(tombstoneOf entityKey: EntityKey, serverVersion: Int, at: Date = Date()) {
        self.entityKey = entityKey
        self.kind = .tombstone
        self.rejectedAt = at
        self.serverVersionAtReject = serverVersion
    }
}

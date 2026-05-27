import Foundation

enum EntityKind: String, Codable, Hashable, Sendable {
    case group, expense, payment, member, receipt
}

struct EntityKey: Hashable, Codable, Sendable {
    let kind: EntityKind
    let id: UUID
    let groupID: UUID

    static func group(_ id: UUID) -> EntityKey {
        EntityKey(kind: .group, id: id, groupID: id)
    }
    static func expense(_ id: UUID, in groupID: UUID) -> EntityKey {
        EntityKey(kind: .expense, id: id, groupID: groupID)
    }
    static func payment(_ id: UUID, in groupID: UUID) -> EntityKey {
        EntityKey(kind: .payment, id: id, groupID: groupID)
    }
    static func member(_ id: UUID, in groupID: UUID) -> EntityKey {
        EntityKey(kind: .member, id: id, groupID: groupID)
    }
    static func receipt(_ id: UUID, in groupID: UUID) -> EntityKey {
        EntityKey(kind: .receipt, id: id, groupID: groupID)
    }
}

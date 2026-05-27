import Foundation

/// Legacy avatar identifier. Retained only so `JSONPersistence` can decode
/// pre-v9 stores and map each case to its corresponding emoji during
/// migration. Never referenced by current models or views.
enum AvatarID: String, Codable, CaseIterable, Hashable {
    case fox, otter, bear, owl, rabbit, cat, fish, deer, frog, panda, koala, wolf

    var legacyEmoji: String {
        switch self {
        case .fox:    return "🦊"
        case .otter:  return "🦦"
        case .bear:   return "🐻"
        case .owl:    return "🦉"
        case .rabbit: return "🐰"
        case .cat:    return "🐱"
        case .fish:   return "🐟"
        case .deer:   return "🦌"
        case .frog:   return "🐸"
        case .panda:  return "🐼"
        case .koala:  return "🐨"
        case .wolf:   return "🐺"
        }
    }
}

/// Expense category. Built-ins (`.food`, `.transport`, etc.) ship with the
/// app — each has a tuned display name, icon, and color. Users can also
/// add arbitrary custom categories via the form's "+ Custom" entry; their
/// `raw` value is a lowercased trimmed string and they fall back to a
/// generic icon / slate tint at render time.
///
/// Codable: emits/parses a bare String so the wire shape is unchanged
/// from when this was a String-backed enum — old persisted stores decode
/// transparently. Dictionary keying ([ExpenseCategory: Int]) still works
/// thanks to Hashable on `raw`.
struct ExpenseCategory: Codable, Hashable {
    let raw: String

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.raw = trimmed.isEmpty ? "other" : trimmed
    }

    init(from decoder: Decoder) throws {
        let stored = try decoder.singleValueContainer().decode(String.self)
        // Preserve whatever the server / disk gave us verbatim. Don't
        // re-normalize here — that would risk collapsing two distinct
        // server-side values that differ only by casing.
        self.raw = stored
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    static let food          = ExpenseCategory("food")
    static let groceries     = ExpenseCategory("groceries")
    static let drinks        = ExpenseCategory("drinks")
    static let transport     = ExpenseCategory("transport")
    static let accommodation = ExpenseCategory("accommodation")
    static let travel        = ExpenseCategory("travel")
    static let entertainment = ExpenseCategory("entertainment")
    static let shopping      = ExpenseCategory("shopping")
    static let gifts         = ExpenseCategory("gifts")
    static let utilities     = ExpenseCategory("utilities")
    static let health        = ExpenseCategory("health")
    static let other         = ExpenseCategory("other")

    /// Canonical order for chip lists / filter bars. Ordered loosely by
    /// frequency of use, with `other` pinned last so the picker reads
    /// like a "common things first → catch-all" list.
    static let builtIn: [ExpenseCategory] = [
        .food, .groceries, .drinks,
        .transport, .accommodation, .travel,
        .entertainment, .shopping, .gifts,
        .utilities, .health,
        .other
    ]

    var isBuiltIn: Bool { Self.builtIn.contains(self) }

    /// Backwards-compat with the prior `CaseIterable` enum. Returns the
    /// built-in set only; callers that also want user-defined categories
    /// should use `availableCategories(in:)` below.
    static var allCases: [ExpenseCategory] { builtIn }

    /// Built-ins + any custom categories actually used by the given
    /// expenses, in a stable order (built-ins first, custom alphabetically).
    /// Used by chip lists and filter UIs so user-defined categories show
    /// up alongside the canonical six.
    static func availableCategories(in expenses: [Expense]) -> [ExpenseCategory] {
        let usedCustom = Set(expenses.map(\.category))
            .subtracting(builtIn)
            .sorted { $0.raw < $1.raw }
        return builtIn + usedCustom
    }
}

struct Member: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var emoji: String
    var joinedAt: Date
    /// Server-side `user_id` for the linked user account. Set whenever
    /// the membership is bound to a real user (host's own seat, or any
    /// member that joined via an invite-accept). Nullable because the
    /// backend's memberships FK is `on_delete: :nullify` — when the owning
    /// user deletes their account, the row stays in `live` scope but
    /// `user_id` is nulled out (a "ghost"). This app is invite-only, so
    /// `userID == nil` on a synced group reliably means "previously linked
    /// user deleted their account."
    var userID: UUID? = nil
    var version: Int = 0
    var updatedAt: Date = .distantPast
    /// Local-only soft-archive marker. When set, the member is hidden from
    /// active UI lists/pickers but still resolves names for historical
    /// expenses and payments. Not synced to the server.
    var archivedAt: Date? = nil

    static let defaultEmoji = "🙂"

    /// True when this membership has no linked user account. In an
    /// invite-only app this means the previously-linked user deleted their
    /// account. Caller should typically gate on the current user being
    /// signed in (see [Member].pickable below) so an anonymous local user's
    /// own unbound seat isn't mistaken for a ghost.
    var isGhost: Bool { userID == nil }
}

extension Array where Element == Member {
    /// Members eligible for inclusion in NEW expense splits / payments /
    /// payer pickers. Excludes archived (locally-hidden) members and ghost
    /// members whose owning user deleted their account. Pass the current
    /// user's `serverID`: when the local user is signed in, an unbound
    /// member can only be a deletion ghost so we filter them; when the
    /// local user is anonymous (no serverID), unbound members might be
    /// the user's own unbound seat, so we keep them.
    ///
    /// Existing expenses' participants/payer still resolve by id elsewhere
    /// (member-by-id lookups), so historical data continues to render with
    /// the ghost's name and emoji.
    func pickable(currentUserServerID: UUID?) -> [Member] {
        filter { member in
            guard member.archivedAt == nil else { return false }
            if currentUserServerID != nil, member.isGhost { return false }
            return true
        }
    }
}

struct ReceiptAttachment: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    var contentType: String
    var byteSize: Int64
    var uploaderUserID: UUID?

    init(id: UUID,
         createdAt: Date,
         contentType: String = "image/jpeg",
         byteSize: Int64 = 0,
         uploaderUserID: UUID? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.contentType = contentType
        self.byteSize = byteSize
        self.uploaderUserID = uploaderUserID
    }

    enum CodingKeys: String, CodingKey {
        case id, createdAt, contentType, byteSize, uploaderUserID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        // Keys absent in pre-v21 on-disk stores; soft-decode so the migration
        // chain produces sane defaults that the backfill helper later patches.
        self.contentType = (try? c.decode(String.self, forKey: .contentType)) ?? "image/jpeg"
        self.byteSize    = (try? c.decode(Int64.self,  forKey: .byteSize))    ?? 0
        self.uploaderUserID = try c.decodeIfPresent(UUID.self, forKey: .uploaderUserID)
    }
}

struct ExpenseShare: Codable, Hashable {
    let memberID: UUID
    let amount: Decimal   // in the expense's own currency (Expense.currencyCode)
}

/// One member's contribution to a multi-payer expense. Mirrors
/// `ExpenseShare` on the credit side — when present, the expense
/// has multiple payers and `payments` sums to `Expense.amount`
/// (within $0.01 tolerance). When the expense uses the single-
/// payer model, this array is nil.
struct ExpensePayment: Codable, Hashable {
    let memberID: UUID
    let amount: Decimal   // in the expense's own currency (Expense.currencyCode)
}

struct Payment: Identifiable, Codable, Hashable {
    let id: UUID
    var fromMemberID: UUID
    var toMemberID: UUID
    var amount: Decimal     // group currency
    var date: Date
    var note: String?
    var expenseIDs: [UUID]? = nil
    var version: Int = 0
    var updatedAt: Date = .distantPast
    var deletedAt: Date? = nil
}

struct Expense: Identifiable, Codable, Hashable {
    let id: UUID
    var payerID: UUID
    var amount: Decimal
    var description: String
    var date: Date
    var participantIDs: [UUID]
    var category: ExpenseCategory = .other
    var receipts: [ReceiptAttachment] = []
    var currencyCode: String
    var exchangeRate: Decimal = 1
    var ratePending: Bool = false
    /// When non-nil, stores the explicit per-member split amounts (in the
    /// expense's own currency). When nil, the expense uses the legacy
    /// equal-split logic driven by `participantIDs`.
    var shares: [ExpenseShare]? = nil
    /// When non-nil, the expense has multiple payers and `payments` sums
    /// to `amount` (within $0.01). When nil, the expense uses the legacy
    /// single-payer model — `payerID` paid the full amount. `payerID`
    /// stays set in either mode and acts as the "primary" payer for
    /// compact display (e.g. expense list rows).
    var payments: [ExpensePayment]? = nil
    /// Local-only metadata: which split UI the user used to author this
    /// expense ("amount" or "percent"). nil = legacy equal-split or
    /// "unknown" — editor falls back to `.amount` mode in that case. Not
    /// synced to the server (server only stores concrete amounts), so on
    /// cross-device edits this degrades gracefully to amount mode.
    var splitKind: String? = nil
    var version: Int = 0
    var updatedAt: Date = .distantPast
    var deletedAt: Date? = nil
}

struct ExpenseGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var emoji: String?
    var currencyCode: String
    var members: [Member]
    var expenses: [Expense]
    var createdAt: Date
    var archivedAt: Date? = nil
    var payments: [Payment]? = nil
    var version: Int = 0
    var updatedAt: Date = .distantPast
    /// Server-side `owner_user_id` for shared/synced groups. Non-nil only
    /// when the group has been pushed to the server. Used to gate host-only
    /// affordances (e.g. "Leave group" vs "Delete") against `user.serverID`.
    var ownerUserID: UUID? = nil
}

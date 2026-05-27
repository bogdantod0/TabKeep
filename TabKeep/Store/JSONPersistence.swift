import Foundation

struct JSONPersistence: GroupsPersistence {
    private struct Wrapper: Codable {
        let version: Int
        let groups: [ExpenseGroup]
        let defaultCurrencyCode: String
        let activityLog: [ActivityEntry]
        let pendingInviteToken: String?
    }

    /// v14 shape: identical wrapper fields to v15; only `ActivityEntry.Kind`
    /// gained a `.draftRecorded` case in v15. v14 files contain no
    /// `.draftRecorded` entries so they decode through `V14Wrapper`
    /// (== current `Wrapper`) without surprise.
    private struct V14Wrapper: Codable {
        let version: Int
        let groups: [ExpenseGroup]
        let defaultCurrencyCode: String
        let activityLog: [ActivityEntry]
    }

    /// v15 shape: identical wrapper fields to v14 (the v14 → v15 bump was a
    /// no-op rebrand introducing the `.draftRecorded` ActivityEntry kind).
    /// Decoded through this struct on disk-format v15, then re-saved as v16
    /// with `pendingInviteToken: nil`.
    private struct V15Wrapper: Codable {
        let version: Int
        let groups: [ExpenseGroup]
        let defaultCurrencyCode: String
        let activityLog: [ActivityEntry]
    }

    /// v13 shape: groups carried `uploadedAt` and `lastSyncCursor`, and the
    /// wrapper had `groupTombstones`/`entityTombstones` (now dropped in v14).
    /// Migrated to v14 by stripping those fields.
    private struct V13Wrapper: Codable {
        let version: Int
        let groups: [V13Group]
        let defaultCurrencyCode: String
        let activityLog: [ActivityEntry]
        // groupTombstones and entityTombstones are intentionally ignored on migration.
    }

    private struct V13Group: Codable {
        let id: UUID
        var name: String
        var emoji: String?
        var currencyCode: String
        var members: [Member]
        var expenses: [Expense]
        var createdAt: Date
        var archivedAt: Date? = nil
        var payments: [Payment]? = nil
        var uploadedAt: Date? = nil
        var version: Int = 0
        var updatedAt: Date = .distantPast
        var lastSyncCursor: Date? = nil
    }

    /// v12 introduced `groupTombstones` (now dropped in v14).
    /// Decoded through this struct, migrated to v14 by dropping tombstones
    /// and uploadedAt/lastSyncCursor.
    private struct V12Wrapper: Codable {
        let version: Int
        let groups: [V13Group]
        let defaultCurrencyCode: String
        let activityLog: [ActivityEntry]
        // groupTombstones is intentionally ignored on migration.
    }

    /// v11 had no tombstones at all. Decoded through this struct, migrated
    /// to v14 by defaulting both tombstone arrays to `[]` and dropping
    /// uploadedAt/lastSyncCursor.
    private struct V11Wrapper: Codable {
        let version: Int
        let groups: [V13Group]
        let defaultCurrencyCode: String
        let activityLog: [ActivityEntry]
    }

    // v8: Member used `avatar: AvatarID` instead of `emoji: String`.
    // The full ExpenseGroup/Expense shape is otherwise unchanged from v9, so
    // we re-decode v5..v8 files through V8Wrapper and remap members.
    private struct V8Wrapper: Codable {
        let version: Int
        let groups: [V8Group]
        let defaultCurrencyCode: String
        let activityLog: [ActivityEntry]
    }

    private struct V8Group: Codable {
        let id: UUID
        var name: String
        var emoji: String?
        var currencyCode: String
        var members: [V8Member]
        var expenses: [Expense]
        var createdAt: Date
        var archivedAt: Date? = nil
        var payments: [Payment]? = nil
    }

    private struct V8Member: Codable, Hashable {
        let id: UUID
        var name: String
        var avatar: AvatarID
        var joinedAt: Date
    }

    // v4: Expense didn't have currencyCode/exchangeRate/ratePending.
    private struct V4Wrapper: Codable {
        let version: Int
        let groups: [V4Group]
        let defaultCurrencyCode: String
        let activityLog: [ActivityEntry]
    }

    private struct V4Group: Codable {
        let id: UUID
        var name: String
        var emoji: String?
        var currencyCode: String
        var members: [V8Member]
        var expenses: [V4Expense]
        var createdAt: Date
    }

    private struct V4Expense: Codable {
        let id: UUID
        var payerID: UUID
        var amount: Decimal
        var description: String
        var date: Date
        var participantIDs: [UUID]
        var category: ExpenseCategory
        var receipts: [ReceiptAttachment]
    }

    private struct V3Wrapper: Codable {
        let version: Int
        let groups: [V4Group]
        let defaultCurrencyCode: String
    }

    private struct V2Wrapper: Codable {
        let version: Int
        let groups: [V2Group]
        let defaultCurrencyCode: String
    }

    private struct V2Group: Codable {
        let id: UUID
        var name: String
        var emoji: String?
        var currencyCode: String
        var members: [V8Member]
        var expenses: [V2Expense]
        var createdAt: Date
    }

    private struct V2Expense: Codable {
        let id: UUID
        var payerID: UUID
        var amount: Decimal
        var description: String
        var date: Date
        var participantIDs: [UUID]
    }

    // v9: snapshot of the pre-v10 group/expense/payment/member shape, before
    // uploadedAt/updatedAt/lastSyncCursor/deletedAt fields were added.
    private struct V9Wrapper: Codable {
        let version: Int
        let groups: [V9Group]
        let activityLog: [ActivityEntry]
        let defaultCurrencyCode: String
    }

    private struct V9Group: Codable {
        let id: UUID
        let name: String
        let emoji: String?
        let currencyCode: String
        let members: [V9Member]
        let expenses: [V9Expense]
        let createdAt: Date
        let archivedAt: Date?
        let payments: [V9Payment]?
    }

    private struct V9Member: Codable {
        let id: UUID
        let name: String
        let emoji: String
        let joinedAt: Date
    }

    private struct V9Expense: Codable {
        let id: UUID
        let payerID: UUID
        let amount: Decimal
        let description: String
        let date: Date
        let participantIDs: [UUID]
        let category: ExpenseCategory
        let receipts: [ReceiptAttachment]
        let currencyCode: String
        let exchangeRate: Decimal
        let ratePending: Bool
        let shares: [ExpenseShare]?
    }

    private struct V9Payment: Codable {
        let id: UUID
        let fromMemberID: UUID
        let toMemberID: UUID
        let amount: Decimal
        let date: Date
        let note: String?
    }

    /// v10: same shape as the current ExpenseGroup but stores the upload
    /// marker as `sharedAt` on disk. v11 renames it to `uploadedAt`.
    private struct V10Wrapper: Codable {
        let version: Int
        let groups: [V10Group]
        let defaultCurrencyCode: String
        let activityLog: [ActivityEntry]
    }

    private struct V10Group: Codable {
        let id: UUID
        var name: String
        var emoji: String?
        var currencyCode: String
        var members: [Member]
        var expenses: [Expense]
        var createdAt: Date
        var archivedAt: Date? = nil
        var payments: [Payment]? = nil
        var sharedAt: Date? = nil
        var updatedAt: Date = .distantPast
        var lastSyncCursor: Date? = nil
    }

    private struct VersionPeek: Decodable {
        let version: Int
    }

    static let currentVersion = 21
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func defaultURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("groups.json")
    }

    func load() throws -> PersistedState {
        let raw = try loadRaw()
        return PersistedState(
            groups: Self.backfillReceiptByteSizes(raw.groups),
            defaultCurrencyCode: raw.defaultCurrencyCode,
            activityLog: raw.activityLog,
            pendingInviteToken: raw.pendingInviteToken
        )
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func loadRaw() throws -> PersistedState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            try quarantineCorruptFile()
            return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let peekedVersion = (try? decoder.decode(VersionPeek.self, from: data))?.version

        switch peekedVersion {
        case 21:
            do {
                let wrapper = try decoder.decode(Wrapper.self, from: data)
                return PersistedState(
                    groups: wrapper.groups,
                    defaultCurrencyCode: wrapper.defaultCurrencyCode,
                    activityLog: wrapper.activityLog,
                    pendingInviteToken: wrapper.pendingInviteToken
                )
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }

        case 20:
            do {
                let wrapper = try decoder.decode(Wrapper.self, from: data)
                let migrated = PersistedState(
                    groups: wrapper.groups,
                    defaultCurrencyCode: wrapper.defaultCurrencyCode,
                    activityLog: wrapper.activityLog,
                    pendingInviteToken: wrapper.pendingInviteToken
                )
                try? save(migrated)
                return migrated
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }

        case 19:
            // v19 → v20 is a no-op rebrand: Payment gained an optional
            // `expenseIDs: [UUID]?` for explicit expense-link metadata. The
            // field defaults to nil for missing keys (synthesized Codable
            // decode), so v19 stores decode through the current Wrapper
            // without surprise. Re-save at v20 on first load.
            do {
                let wrapper = try decoder.decode(Wrapper.self, from: data)
                let migrated = PersistedState(
                    groups: wrapper.groups,
                    defaultCurrencyCode: wrapper.defaultCurrencyCode,
                    activityLog: wrapper.activityLog,
                    pendingInviteToken: wrapper.pendingInviteToken
                )
                try? save(migrated)
                return migrated
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }

        case 18:
            // v18 → v19 is a no-op rebrand: Expense gained an optional
            // `payments: [ExpensePayment]?` for multi-payer expenses. The
            // field defaults to nil for missing keys (synthesized Codable
            // decode), so v18 stores decode through the current Wrapper
            // without surprise. Re-save at v19 on first load.
            do {
                let wrapper = try decoder.decode(Wrapper.self, from: data)
                let migrated = PersistedState(
                    groups: wrapper.groups,
                    defaultCurrencyCode: wrapper.defaultCurrencyCode,
                    activityLog: wrapper.activityLog,
                    pendingInviteToken: wrapper.pendingInviteToken
                )
                try? save(migrated)
                return migrated
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }

        case 17:
            // v17 → v18 is a no-op rebrand: ActivityEntry.Kind gained a new
            // `.paymentEdited` case in v18. v17 files contain no such entries
            // so they decode through the current Wrapper without surprise.
            // Re-save at v18 on first load to mark the bump.
            do {
                let wrapper = try decoder.decode(Wrapper.self, from: data)
                let migrated = PersistedState(
                    groups: wrapper.groups,
                    defaultCurrencyCode: wrapper.defaultCurrencyCode,
                    activityLog: wrapper.activityLog,
                    pendingInviteToken: wrapper.pendingInviteToken
                )
                try? save(migrated)
                return migrated
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }

        case 16:
            // v16 → v17 is a no-op shape change at the wrapper level: Member
            // gains an optional `archivedAt: Date?` that defaults to nil when
            // missing, so v16 stores decode cleanly through the current
            // Wrapper. Re-save at v17 on first load.
            do {
                let wrapper = try decoder.decode(Wrapper.self, from: data)
                let migrated = PersistedState(
                    groups: wrapper.groups,
                    defaultCurrencyCode: wrapper.defaultCurrencyCode,
                    activityLog: wrapper.activityLog,
                    pendingInviteToken: wrapper.pendingInviteToken
                )
                try? save(migrated)
                return migrated
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }

        case 15:
            // v15 → v16 is a no-op shape change at the group level: the wrapper
            // gains pendingInviteToken (defaults to nil for migrated stores).
            do {
                let v15 = try decoder.decode(V15Wrapper.self, from: data)
                let migrated = PersistedState(
                    groups: v15.groups,
                    defaultCurrencyCode: v15.defaultCurrencyCode,
                    activityLog: v15.activityLog,
                    pendingInviteToken: nil
                )
                try? save(migrated)
                return migrated
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }

        case 14:
            // v14 → v15 is a no-op rebrand: the on-disk shape didn't change,
            // only `ActivityEntry.Kind` gained a new `.draftRecorded` case
            // that v14 files cannot contain. Decode through V14Wrapper and
            // re-save at v15.
            do {
                let v14 = try decoder.decode(V14Wrapper.self, from: data)
                let migrated = PersistedState(
                    groups: v14.groups,
                    defaultCurrencyCode: v14.defaultCurrencyCode,
                    activityLog: v14.activityLog
                )
                try? save(migrated)
                return migrated
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }

        case 13:
            do {
                let v13 = try decoder.decode(V13Wrapper.self, from: data)
                let migrated = PersistedState(
                    groups: v13.groups.map(Self.migrateGroupV13toV14),
                    defaultCurrencyCode: v13.defaultCurrencyCode,
                    activityLog: v13.activityLog
                )
                try? save(migrated)
                return migrated
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }

        case 12:
            do {
                let v12 = try decoder.decode(V12Wrapper.self, from: data)
                let migrated = PersistedState(
                    groups: v12.groups.map(Self.migrateGroupV13toV14),
                    defaultCurrencyCode: v12.defaultCurrencyCode,
                    activityLog: v12.activityLog
                )
                try? save(migrated)
                return migrated
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }

        case 11:
            do {
                let v11 = try decoder.decode(V11Wrapper.self, from: data)
                let migrated = PersistedState(
                    groups: v11.groups.map(Self.migrateGroupV13toV14),
                    defaultCurrencyCode: v11.defaultCurrencyCode,
                    activityLog: v11.activityLog
                )
                try? save(migrated)
                return migrated
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }

        case 10:
            do {
                let v10 = try decoder.decode(V10Wrapper.self, from: data)
                let migrated = PersistedState(
                    groups: v10.groups.map(Self.migrateGroupV10toV11),
                    defaultCurrencyCode: v10.defaultCurrencyCode,
                    activityLog: v10.activityLog
                )
                try? save(migrated)
                return migrated
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }

        case 9:
            do {
                let v9 = try decoder.decode(V9Wrapper.self, from: data)
                let migrated = PersistedState(
                    groups: v9.groups.map(Self.migrateGroupV9toV10),
                    defaultCurrencyCode: v9.defaultCurrencyCode,
                    activityLog: v9.activityLog
                )
                try? save(migrated)
                return migrated
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }

        case 8, 7, 6, 5:
            // v5..v8 share the same shape modulo additive optional fields, but
            // their Member uses `avatar: AvatarID`. Decode as V8Wrapper, remap
            // members to emoji, then rewrite as v9.
            do {
                let v8 = try decoder.decode(V8Wrapper.self, from: data)
                let migrated = PersistedState(
                    groups: v8.groups.map(Self.migrateGroupV8toV9),
                    defaultCurrencyCode: v8.defaultCurrencyCode,
                    activityLog: v8.activityLog
                )
                try? save(migrated)
                return migrated
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }

        case 4:
            let v4: V4Wrapper
            do {
                v4 = try decoder.decode(V4Wrapper.self, from: data)
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }
            let migrated = PersistedState(
                groups: v4.groups.map(Self.migrateGroupV4toV9),
                defaultCurrencyCode: v4.defaultCurrencyCode,
                activityLog: v4.activityLog
            )
            try? save(migrated)
            return migrated

        case 3:
            let v3: V3Wrapper
            do {
                v3 = try decoder.decode(V3Wrapper.self, from: data)
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }
            let migrated = PersistedState(
                groups: v3.groups.map(Self.migrateGroupV4toV9),
                defaultCurrencyCode: v3.defaultCurrencyCode,
                activityLog: []
            )
            try? save(migrated)
            return migrated

        case 2:
            let v2: V2Wrapper
            do {
                v2 = try decoder.decode(V2Wrapper.self, from: data)
            } catch {
                try quarantineCorruptFile()
                return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
            }
            let migrated = PersistedState(
                groups: v2.groups.map(Self.migrateGroupV2toV9),
                defaultCurrencyCode: v2.defaultCurrencyCode,
                activityLog: []
            )
            try? save(migrated)
            return migrated

        default:
            try quarantineCorruptFile()
            return PersistedState(groups: [], defaultCurrencyCode: Self.localeCurrencyCode())
        }
    }

    func save(_ state: PersistedState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let wrapper = Wrapper(
            version: Self.currentVersion,
            groups: state.groups,
            defaultCurrencyCode: state.defaultCurrencyCode,
            activityLog: state.activityLog,
            pendingInviteToken: state.pendingInviteToken
        )
        let data = try encoder.encode(wrapper)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func migrateGroupV8toV9(_ g: V8Group) -> ExpenseGroup {
        var group = ExpenseGroup(
            id: g.id,
            name: g.name,
            emoji: g.emoji,
            currencyCode: g.currencyCode,
            members: g.members.map(migrateMemberV8toV9),
            expenses: g.expenses,
            createdAt: g.createdAt,
            archivedAt: g.archivedAt,
            payments: g.payments
        )
        baselineV10(&group)
        return group
    }

    private static func migrateMemberV8toV9(_ m: V8Member) -> Member {
        Member(id: m.id, name: m.name, emoji: m.avatar.legacyEmoji, joinedAt: m.joinedAt)
    }

    private static func migrateGroupV4toV9(_ g: V4Group) -> ExpenseGroup {
        var group = ExpenseGroup(
            id: g.id,
            name: g.name,
            emoji: g.emoji,
            currencyCode: g.currencyCode,
            members: g.members.map(migrateMemberV8toV9),
            expenses: g.expenses.map { migrateExpenseV4toV5($0, groupCurrency: g.currencyCode) },
            createdAt: g.createdAt
        )
        baselineV10(&group)
        return group
    }

    private static func migrateExpenseV4toV5(_ e: V4Expense, groupCurrency: String) -> Expense {
        Expense(
            id: e.id,
            payerID: e.payerID,
            amount: e.amount,
            description: e.description,
            date: e.date,
            participantIDs: e.participantIDs,
            category: e.category,
            receipts: e.receipts,
            currencyCode: groupCurrency,
            exchangeRate: 1,
            ratePending: false
        )
    }

    private static func migrateGroupV2toV9(_ g: V2Group) -> ExpenseGroup {
        var group = ExpenseGroup(
            id: g.id,
            name: g.name,
            emoji: g.emoji,
            currencyCode: g.currencyCode,
            members: g.members.map(migrateMemberV8toV9),
            expenses: g.expenses.map { migrateExpenseV2toV5($0, groupCurrency: g.currencyCode) },
            createdAt: g.createdAt
        )
        baselineV10(&group)
        return group
    }

    private static func migrateExpenseV2toV5(_ e: V2Expense, groupCurrency: String) -> Expense {
        Expense(
            id: e.id,
            payerID: e.payerID,
            amount: e.amount,
            description: e.description,
            date: e.date,
            participantIDs: e.participantIDs,
            category: .other,
            receipts: [],
            currencyCode: groupCurrency,
            exchangeRate: 1,
            ratePending: false
        )
    }

    /// Stamps all v10 timestamp fields (`updatedAt`) on the group and each of
    /// its members/expenses/payments with the group's `createdAt` so migrated
    /// data round-trips through the v10 wrapper with sane defaults rather than
    /// `.distantPast`. Called from every pre-v9 migration helper.
    private static func baselineV10(_ group: inout ExpenseGroup) {
        let baseline = group.createdAt
        group.updatedAt = baseline
        group.members = group.members.map { m in
            var m = m
            m.updatedAt = baseline
            return m
        }
        group.expenses = group.expenses.map { e in
            var e = e
            e.updatedAt = baseline
            return e
        }
        if let payments = group.payments {
            group.payments = payments.map { p in
                var p = p
                p.updatedAt = baseline
                return p
            }
        }
    }

    private static func migrateGroupV9toV10(_ g: V9Group) -> ExpenseGroup {
        let baseline = g.createdAt
        let members = g.members.map { m in
            Member(id: m.id, name: m.name, emoji: m.emoji,
                   joinedAt: m.joinedAt, updatedAt: baseline)
        }
        let expenses = g.expenses.map { e in
            Expense(id: e.id, payerID: e.payerID, amount: e.amount,
                    description: e.description, date: e.date,
                    participantIDs: e.participantIDs, category: e.category,
                    receipts: e.receipts, currencyCode: e.currencyCode,
                    exchangeRate: e.exchangeRate, ratePending: e.ratePending,
                    shares: e.shares, updatedAt: baseline, deletedAt: nil)
        }
        let payments = (g.payments ?? []).map { p in
            Payment(id: p.id, fromMemberID: p.fromMemberID, toMemberID: p.toMemberID,
                    amount: p.amount, date: p.date, note: p.note,
                    updatedAt: baseline, deletedAt: nil)
        }
        return ExpenseGroup(
            id: g.id, name: g.name, emoji: g.emoji,
            currencyCode: g.currencyCode, members: members, expenses: expenses,
            createdAt: g.createdAt, archivedAt: g.archivedAt, payments: payments,
            updatedAt: baseline
        )
    }

    private static func migrateGroupV10toV11(_ g: V10Group) -> ExpenseGroup {
        ExpenseGroup(
            id: g.id, name: g.name, emoji: g.emoji,
            currencyCode: g.currencyCode, members: g.members, expenses: g.expenses,
            createdAt: g.createdAt, archivedAt: g.archivedAt, payments: g.payments,
            updatedAt: g.updatedAt
        )
    }

    private static func migrateGroupV13toV14(_ g: V13Group) -> ExpenseGroup {
        ExpenseGroup(
            id: g.id, name: g.name, emoji: g.emoji,
            currencyCode: g.currencyCode, members: g.members, expenses: g.expenses,
            createdAt: g.createdAt, archivedAt: g.archivedAt, payments: g.payments,
            version: g.version, updatedAt: g.updatedAt
        )
    }

    /// Reads JPEG byte size from `ReceiptStore` for receipts whose `byteSize`
    /// is zero — true for any receipt persisted before v21. If the file is
    /// missing on disk, drop the receipt entry; we have no recoverable bytes
    /// and the parent expense already wouldn't render a thumbnail.
    ///
    /// Called unconditionally at the tail of every `load()` path (including
    /// `case 21:`). The guard `r.byteSize == 0` makes it a no-op for receipts
    /// already carrying a non-zero size, so v21 stores pay only a Dictionary
    /// lookup per receipt. This ensures every migration arm — not just `case
    /// 20:` — gets backfilled, covering users who upgrade from v3–v19.
    private static func backfillReceiptByteSizes(_ groups: [ExpenseGroup]) -> [ExpenseGroup] {
        let store = ReceiptStore.default()
        let fm = FileManager.default
        return groups.map { group in
            var g = group
            g.expenses = group.expenses.map { expense in
                var e = expense
                e.receipts = expense.receipts.compactMap { r in
                    guard r.byteSize == 0 else { return r }
                    let url = store.url(for: r.id)
                    guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                          let size = attrs[.size] as? NSNumber else {
                        return nil    // dangling reference — drop
                    }
                    return ReceiptAttachment(
                        id: r.id,
                        createdAt: r.createdAt,
                        contentType: r.contentType,
                        byteSize: size.int64Value,
                        uploaderUserID: r.uploaderUserID
                    )
                }
                return e
            }
            return g
        }
    }

    private func quarantineCorruptFile() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let ts = Int(Date().timeIntervalSince1970)
        let renamed = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(ts)")
        try FileManager.default.moveItem(at: fileURL, to: renamed)
    }

    private static func localeCurrencyCode() -> String {
        Locale.current.currency?.identifier ?? "USD"
    }
}

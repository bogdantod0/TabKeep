import Foundation
import os

/// HTTP-backed GroupsRepository. Local-only methods throw
/// RepositoryError.unavailable — the Hybrid repository routes those
/// to LocalGroupsRepository instead.
actor RemoteGroupsRepository: GroupsRepository {
    private let api: APIClient
    private let tokenProvider: @Sendable () async -> String?
    /// Returns the authenticated user's identity (name-match key and
    /// server user ID). Used to detect when a member being PUT is the
    /// host's own seat so we can send `user_id: <current_user.id>` and
    /// have the server bind the membership to `current_user`. The match
    /// key is the lowercased trimmed display name; the server ID is the
    /// authenticated user's `id` (nil for an anon device that hasn't
    /// registered yet — in which case the membership stays a ghost
    /// until `registerAnonymousDevice` lands).
    private let userIdentityProvider: @Sendable () async -> (matchKey: String?, serverID: UUID?)
    private let log = Logger(subsystem: "com.example.tabkeep", category: "remote-repo")

    init(
        api: APIClient,
        tokenProvider: @escaping @Sendable () async -> String?,
        userIdentityProvider: @escaping @Sendable () async -> (matchKey: String?, serverID: UUID?) = { (nil, nil) }
    ) {
        self.api = api
        self.tokenProvider = tokenProvider
        self.userIdentityProvider = userIdentityProvider
    }

    // MARK: - GroupsRepository

    func loadAll() async throws -> PersistedState {
        throw RepositoryError.unavailable
    }

    func saveLocal(_ state: PersistedState) async throws {
        throw RepositoryError.unavailable
    }

    // MARK: - Server reads

    func listShared() async throws -> [ExpenseGroup] {
        guard let token = await tokenProvider() else { throw RepositoryError.notSignedIn }
        let dtos = try await api.listGroups(token: token)
        return dtos.compactMap(toExpenseGroup)
    }

    func fetchShared(id: UUID) async throws -> ExpenseGroup {
        guard let token = await tokenProvider() else { throw RepositoryError.notSignedIn }
        let dto = try await api.getGroup(token: token, id: id)
        guard let group = toExpenseGroup(dto) else {
            throw APIError.decoding("group missing required fields")
        }
        return group
    }

    func refresh(groupID: UUID) async throws -> ExpenseGroup {
        try await fetchShared(id: groupID)
    }

    // MARK: - PUT-as-upsert (Phase 3 sync)

    func putGroup(_ group: ExpenseGroup) async throws -> MutationOutcome<ExpenseGroup> {
        guard let token = await tokenProvider() else { throw RepositoryError.notSignedIn }
        let body = GroupUpsertDTO(
            id: group.id,
            name: group.name,
            emoji: group.emoji,
            currencyCode: group.currencyCode,
            archivedAt: group.archivedAt,
            version: group.version
        )
        do {
            let dto = try await api.putGroup(token: token, id: group.id, body: body)
            guard let model = toExpenseGroup(dto) else { throw APIError.decoding("group put decode failed") }
            return .applied(model)
        } catch APIError.staleWrite(let raw) {
            let dto = try JSONDecoder.snakeIso8601().decode(GroupDTO.self, from: raw)
            guard let model = toExpenseGroup(dto) else { throw APIError.decoding("stale group decode failed") }
            return .staleWrite(model)
        }
    }

    func putExpense(_ expense: Expense, in groupID: UUID) async throws -> MutationOutcome<Expense> {
        guard let token = await tokenProvider() else { throw RepositoryError.notSignedIn }
        let body = expenseUpsertBody(expense, groupID: groupID)
        do {
            let dto = try await api.putExpense(token: token, id: expense.id, body: body)
            guard let model = toExpense(dto) else { throw APIError.decoding("expense put decode failed") }
            return .applied(model)
        } catch APIError.staleWrite(let raw) {
            let dto = try JSONDecoder.snakeIso8601().decode(ExpenseDTO.self, from: raw)
            guard let model = toExpense(dto) else { throw APIError.decoding("stale expense decode failed") }
            return .staleWrite(model)
        }
    }

    func putPayment(_ payment: Payment, in groupID: UUID) async throws -> MutationOutcome<Payment> {
        guard let token = await tokenProvider() else { throw RepositoryError.notSignedIn }
        let body = paymentUpsertBody(payment, groupID: groupID)
        do {
            let dto = try await api.putPayment(token: token, id: payment.id, body: body)
            guard let model = toPayment(dto) else { throw APIError.decoding("payment put decode failed") }
            return .applied(model)
        } catch APIError.staleWrite(let raw) {
            let dto = try JSONDecoder.snakeIso8601().decode(PaymentDTO.self, from: raw)
            guard let model = toPayment(dto) else { throw APIError.decoding("stale payment decode failed") }
            return .staleWrite(model)
        }
    }

    func putMember(_ member: Member, in groupID: UUID) async throws -> MutationOutcome<Member> {
        guard let token = await tokenProvider() else { throw RepositoryError.notSignedIn }
        let identity = await userIdentityProvider()
        let memberKey = member.name.trimmingCharacters(in: .whitespaces).lowercased()
        let isHostSeat: Bool = {
            guard let key = identity.matchKey, !key.isEmpty else { return false }
            return key == memberKey
        }()
        // Server binds `user_id` only when it equals `current_user.id`.
        // Send the authenticated user's serverID when this seat is the
        // host's own; otherwise nil so the seat stays a ghost. Member's
        // own stored `userID` (set after a previous successful bind) is
        // also acceptable but the name-match keeps the host's first PUT
        // working before `userID` has been populated locally.
        let userID: UUID?
        if isHostSeat, let serverID = identity.serverID {
            userID = serverID
        } else if let existing = member.userID {
            // Subsequent updates of an already-bound seat: echo back the
            // bound `user_id` so the server doesn't reset it to nil.
            userID = existing
        } else {
            userID = nil
        }
        let body = MembershipUpsertDTO(
            id: member.id,
            groupID: groupID,
            displayName: member.name,
            emoji: member.emoji,
            updatedAt: member.updatedAt,
            version: member.version,
            userID: userID
        )
        do {
            let dto = try await api.putMembership(token: token, id: member.id, body: body)
            return .applied(toMember(dto))
        } catch APIError.staleWrite(let raw) {
            let dto = try JSONDecoder.snakeIso8601().decode(MembershipDTO.self, from: raw)
            return .staleWrite(toMember(dto))
        }
    }

    // MARK: - Receipt step helpers (Task 6)

    /// Returned by `pushReceiptMetadata` so the drainer can advance to the bytes step.
    struct ReceiptUploadTicket: Sendable {
        let uploadURL: URL
        let headers: [String: String]
    }

    /// POST /api/v1/expenses/:expenseID/receipts. Server's with_idempotency block
    /// is keyed on the Idempotency-Key header (set in APIClient.createReceipt).
    func pushReceiptMetadata(
        expenseID: UUID,
        receiptID: UUID,
        contentType: String,
        byteSize: Int64
    ) async throws -> ReceiptUploadTicket {
        guard let token = await tokenProvider() else { throw RepositoryError.notSignedIn }
        let resp = try await api.createReceipt(
            token: token,
            expenseID: expenseID,
            id: receiptID,
            contentType: contentType,
            byteSize: byteSize
        )
        return ReceiptUploadTicket(uploadURL: resp.uploadURL, headers: resp.headers)
    }

    /// Streams the JPEG from `fileURL` to the presigned S3/MinIO URL.
    func pushReceiptBytes(to url: URL, headers: [String: String], fileURL: URL) async throws {
        try await api.putReceiptBytes(to: url, headers: headers, fileURL: fileURL)
    }

    /// POST /api/v1/receipts/:id/finalize. 204 on success; 422 with
    /// reason "object_missing"/"byte_size_mismatch" surfaces via
    /// APIError.server.reason for the drainer to reset on.
    func pushReceiptFinalize(receiptID: UUID) async throws {
        guard let token = await tokenProvider() else { throw RepositoryError.notSignedIn }
        try await api.finalizeReceipt(token: token, id: receiptID)
    }

    /// DELETE /api/v1/receipts/:id.
    func deleteReceiptRemote(receiptID: UUID) async throws {
        guard let token = await tokenProvider() else { throw RepositoryError.notSignedIn }
        try await api.deleteReceipt(token: token, id: receiptID)
    }

    /// GET /api/v1/receipts/:id — returns the presigned download URL.
    func receiptDownloadURL(receiptID: UUID) async throws -> URL {
        guard let token = await tokenProvider() else { throw RepositoryError.notSignedIn }
        return try await api.getReceiptDownloadURL(token: token, id: receiptID)
    }

    // MARK: - DELETE versioned (Phase 3 sync)

    // On 409 stale-write the server returns its current entity in the
    // envelope's `details.current`. The user's intent here is "delete this
    // thing" — a stale `If-Match-Version` almost always means our own
    // concurrent edit (e.g., adding an expense bumped the group's version)
    // rather than a real conflict with another device. Auto-retry once with
    // the server's fresh version. If the retry STILL 409s, surface as a
    // conflict so the drainer can ask the user via banner.

    func deleteGroupVersioned(id: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void> {
        guard let token = await tokenProvider() else { throw RepositoryError.notSignedIn }
        do {
            try await api.deleteGroupV2(token: token, id: id, ifMatchVersion: ifMatchVersion)
            return .applied(())
        } catch APIError.staleWrite(let raw) {
            guard let dto = try? JSONDecoder.snakeIso8601().decode(GroupDTO.self, from: raw) else {
                return .staleWrite(())
            }
            do {
                try await api.deleteGroupV2(token: token, id: id, ifMatchVersion: dto.version)
                return .applied(())
            } catch APIError.staleWrite {
                return .staleWrite(())
            }
        }
    }

    func deleteExpenseVersioned(id: UUID, in groupID: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void> {
        guard let token = await tokenProvider() else { throw RepositoryError.notSignedIn }
        do {
            try await api.deleteExpenseV2(token: token, id: id, ifMatchVersion: ifMatchVersion)
            return .applied(())
        } catch APIError.staleWrite(let raw) {
            guard let dto = try? JSONDecoder.snakeIso8601().decode(ExpenseDTO.self, from: raw) else {
                return .staleWrite(())
            }
            do {
                try await api.deleteExpenseV2(token: token, id: id, ifMatchVersion: dto.version)
                return .applied(())
            } catch APIError.staleWrite {
                return .staleWrite(())
            }
        }
    }

    func deletePaymentVersioned(id: UUID, in groupID: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void> {
        guard let token = await tokenProvider() else { throw RepositoryError.notSignedIn }
        do {
            try await api.deletePaymentV2(token: token, id: id, ifMatchVersion: ifMatchVersion)
            return .applied(())
        } catch APIError.staleWrite(let raw) {
            guard let dto = try? JSONDecoder.snakeIso8601().decode(PaymentDTO.self, from: raw) else {
                return .staleWrite(())
            }
            do {
                try await api.deletePaymentV2(token: token, id: id, ifMatchVersion: dto.version)
                return .applied(())
            } catch APIError.staleWrite {
                return .staleWrite(())
            }
        }
    }

    func deleteMemberVersioned(id: UUID, in groupID: UUID, ifMatchVersion: Int) async throws -> MutationOutcome<Void> {
        guard let token = await tokenProvider() else { throw RepositoryError.notSignedIn }
        do {
            try await api.deleteMembershipV2(token: token, id: id, ifMatchVersion: ifMatchVersion)
            return .applied(())
        } catch APIError.staleWrite(let raw) {
            guard let dto = try? JSONDecoder.snakeIso8601().decode(MembershipDTO.self, from: raw) else {
                return .staleWrite(())
            }
            do {
                try await api.deleteMembershipV2(token: token, id: id, ifMatchVersion: dto.version)
                return .applied(())
            } catch APIError.staleWrite {
                return .staleWrite(())
            }
        }
    }

    // MARK: - DTO ↔ model mapping

    private func toExpenseGroup(_ d: GroupDTO) -> ExpenseGroup? {
        ExpenseGroup(
            id: d.id,
            name: d.name,
            emoji: d.emoji,
            currencyCode: d.currencyCode,
            members: d.memberships.map(toMember),
            expenses: d.expenses.compactMap(toExpense),
            createdAt: d.createdAt,
            archivedAt: d.archivedAt,
            payments: d.payments.compactMap(toPayment),
            version: d.version,
            updatedAt: d.updatedAt,
            ownerUserID: d.ownerUserID
        )
    }

    private func toMember(_ d: MembershipDTO) -> Member {
        Member(id: d.id, name: d.displayName, emoji: d.emoji,
               joinedAt: d.joinedAt, userID: d.userID,
               version: d.version, updatedAt: d.updatedAt)
    }

    private func toExpense(_ d: ExpenseDTO) -> Expense? {
        // Filter out soft-deleted entries — the model never carries them.
        if d.deletedAt != nil { return nil }
        let category = ExpenseCategory(d.category)
        let shares = d.shares.isEmpty ? nil : d.shares.map { s in
            ExpenseShare(memberID: s.membershipID, amount: s.amount.value)
        }
        // Multi-payer payments — non-empty array means the expense has
        // multiple payers; nil/empty means single-payer (payerID alone).
        let payments: [ExpensePayment]? = {
            guard let pays = d.payments, !pays.isEmpty else { return nil }
            return pays.map { ExpensePayment(memberID: $0.membershipID, amount: $0.amount.value) }
        }()
        // Defensive: older server builds returned empty participant_membership_ids
        // for shares-mode expenses (because the rows live in expense_shares,
        // not expense_participants). Derive participants from shares when the
        // server's list is empty so local state always has them populated —
        // otherwise BalanceCalculator and the editor's split-mode reasoning
        // can't determine who's involved.
        let participants: [UUID] = d.participantMembershipIDs.isEmpty
            ? (shares?.map(\.memberID) ?? [])
            : d.participantMembershipIDs
        // Server's _expense.json.jbuilder filters to `receipts.live.ready`,
        // so the wire only carries ready receipts. Defensive filter mirrors
        // that — a mid-finalize race that ever surfaces a pending row here
        // would be silently dropped rather than flashing a half-uploaded
        // thumbnail.
        let receipts: [ReceiptAttachment] = (d.receipts ?? []).compactMap { r in
            guard r.state == "ready" else { return nil }
            return ReceiptAttachment(
                id: r.id,
                createdAt: r.createdAt,
                contentType: r.contentType,
                byteSize: r.byteSize,
                uploaderUserID: r.uploaderUserID
            )
        }
        return Expense(
            id: d.id,
            payerID: d.payerMembershipID,
            amount: d.amount.value,
            description: d.description,
            date: d.occurredAt,
            participantIDs: participants,
            category: category,
            receipts: receipts,
            currencyCode: d.currencyCode,
            exchangeRate: d.exchangeRate.value,
            ratePending: d.ratePending,
            shares: shares,
            payments: payments,
            version: d.version,
            updatedAt: d.updatedAt,
            deletedAt: nil
        )
    }

    private func toPayment(_ d: PaymentDTO) -> Payment? {
        if d.deletedAt != nil { return nil }
        return Payment(
            id: d.id,
            fromMemberID: d.fromMembershipID,
            toMemberID: d.toMembershipID,
            amount: d.amount.value,
            date: d.occurredAt,
            note: d.note,
            expenseIDs: d.expenseIDs,
            version: d.version,
            updatedAt: d.updatedAt,
            deletedAt: nil
        )
    }

    // MARK: - Upsert body builders

    private func expenseUpsertBody(_ e: Expense, groupID: UUID) -> ExpenseUpsertDTO {
        let shares = e.shares?.map { s in
            ExpenseShareDTO(membershipID: s.memberID, amount: DecimalString(s.amount))
        }
        let payments = e.payments?.map { p in
            ExpensePaymentDTO(membershipID: p.memberID, amount: DecimalString(p.amount))
        }
        return ExpenseUpsertDTO(
            id: e.id,
            groupID: groupID,
            payerMembershipID: e.payerID,
            amount: DecimalString(e.amount),
            currencyCode: e.currencyCode,
            exchangeRate: DecimalString(e.exchangeRate),
            ratePending: e.ratePending,
            description: e.description,
            category: e.category.raw,
            occurredAt: e.date,
            participantMembershipIDs: shares == nil ? e.participantIDs : nil,
            shares: shares,
            payments: payments,
            updatedAt: e.updatedAt,
            version: e.version
        )
    }

    private func paymentUpsertBody(_ p: Payment, groupID: UUID) -> PaymentUpsertDTO {
        PaymentUpsertDTO(
            id: p.id,
            groupID: groupID,
            fromMembershipID: p.fromMemberID,
            toMembershipID: p.toMemberID,
            amount: DecimalString(p.amount),
            occurredAt: p.date,
            note: p.note,
            expenseIDs: p.expenseIDs,
            updatedAt: p.updatedAt,
            version: p.version
        )
    }
}

private extension JSONDecoder {
    /// Used inside the repository for re-decoding stale-write payloads.
    /// Mirrors APIClient's date strategy: try fractional then non-fractional
    /// ISO8601.
    static func snakeIso8601() -> JSONDecoder {
        let dec = JSONDecoder()
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let d = f1.date(from: s) { return d }
            if let d = f2.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
        }
        return dec
    }
}

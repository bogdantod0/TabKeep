import Foundation

/// Returned by AppStore.entityProvider for `.receipt` keys. Carries enough
/// to drive the POST without a model re-traversal.
struct ReceiptDrainLocal: Sendable {
    let receipt: ReceiptAttachment
    let expenseID: UUID
}

actor SyncDrainer {
    typealias EntityProvider = @Sendable (EntityKey) async -> Any?
    typealias EventApplier = @Sendable (ServerEvent) async -> Void
    typealias SignedInProbe = @Sendable () async -> Bool

    private let state: SyncState
    private let remote: RemoteGroupsRepository
    private let entityProvider: EntityProvider
    private let apply: EventApplier
    private let isSignedIn: SignedInProbe
    private var draining: Bool = false

    init(state: SyncState,
         remote: RemoteGroupsRepository,
         entityProvider: @escaping EntityProvider,
         apply: @escaping EventApplier,
         isSignedIn: @escaping SignedInProbe) {
        self.state = state
        self.remote = remote
        self.entityProvider = entityProvider
        self.apply = apply
        self.isSignedIn = isSignedIn
    }

    /// Best-effort drain. Returns immediately if a drain is already running.
    /// Callers that NEED the drain to finish (sign-out) should use
    /// `drainNow()` instead.
    func kick() async {
        guard !draining else { return }
        guard await isSignedIn() else { return }
        draining = true
        defer { draining = false }
        await drainLoop()
    }

    /// Synchronous drain that ensures all currently-pending entries are
    /// processed before returning. Used by sign-out's dropAll: we MUST land
    /// pending tombstones server-side before wiping syncState, otherwise the
    /// next sign-in resurrects locally-deleted entities via listShared.
    ///
    /// If a drain is already in flight, waits for it to finish, then runs
    /// another pass to pick up anything enqueued during the in-flight drain.
    func drainNow() async {
        // Spin until either we get to run a drain ourselves, or the in-flight
        // drain finishes and there's nothing left to do. Bounded to avoid
        // looping forever on a wedged drain.
        for _ in 0..<10 {
            if draining {
                // Yield and re-check; the in-flight drain will set draining=false
                // when it completes.
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
                continue
            }
            guard await isSignedIn() else { return }
            draining = true
            await drainLoop()
            draining = false
            // If nothing pending, we're done.
            if await state.nextPending() == nil { return }
        }
    }

    private func drainLoop() async {
        while await isSignedIn() {
            guard let pending = await state.nextPending() else { return }
            do {
                try await drainOne(pending)
            } catch APIError.transport {
                return
            } catch APIError.server(_, _, let status, _) where status >= 500 {
                // Transient server error — keep the dirty / tombstone entry
                // so the next kick retries. Symmetric with `.transport`.
                return
            } catch APIError.server(let code, _, _, _) where code == "auth_invalid" {
                return
            } catch APIError.server(let code, _, _, _) where code == "not_found" {
                await state.clear(pending.key)
                if pending.key.kind == .group {
                    await apply(.groupGoneOnServer(pending.key.id))
                }
            } catch APIError.server(let code, _, _, _) where code == "forbidden" {
                // Permanent rejection — current user isn't allowed to mutate
                // this entity (e.g. non-host / non-payer / non-participant
                // trying to delete an expense). Clear the dirty / tombstone
                // entry so we don't retry forever; AppStore reacts by
                // refreshing the group (which resurrects the local entity
                // from server state) and surfacing a permission-denied banner.
                let action: PermissionDeniedAction = pending.isDelete ? .delete : .upsert
                await state.clear(pending.key)
                await apply(.permissionDenied(pending.key, action: action))
            } catch {
                await state.clear(pending.key)
                let local = await entityProvider(pending.key)
                await apply(.conflict(pending.key, server: nil, rejectedLocal: local))
            }
        }
    }

    private func drainOne(_ pending: SyncState.Pending) async throws {
        switch pending {
        case .upsert(let k):
            guard let local = await entityProvider(k) else {
                await state.clear(k)
                return
            }
            try await drainUpsert(k, local: local)
        case .delete(let k, let v):
            try await drainDelete(k, version: v)
        }
    }

    private func drainUpsert(_ k: EntityKey, local: Any) async throws {
        let outcome: MutationOutcome<Any>
        switch k.kind {
        case .group:
            let typed = local as! ExpenseGroup
            let r = try await remote.putGroup(typed)
            outcome = mapOutcome(r)
        case .expense:
            let typed = local as! Expense
            let r = try await remote.putExpense(typed, in: k.groupID)
            outcome = mapOutcome(r)
        case .payment:
            let typed = local as! Payment
            let r = try await remote.putPayment(typed, in: k.groupID)
            outcome = mapOutcome(r)
        case .member:
            let typed = local as! Member
            let r = try await remote.putMember(typed, in: k.groupID)
            outcome = mapOutcome(r)
        case .receipt:
            guard let drainLocal = local as? ReceiptDrainLocal else {
                // AppStore.entityProvider hasn't been wired for .receipt yet (T7).
                // Clear the key defensively — we'll get re-marked when T7 ships.
                await state.clear(k)
                return
            }
            try await pushReceipt(key: k, local: drainLocal)
            return
        }

        switch outcome {
        case .applied(let server):
            await state.clear(k)
            await apply(.upserted(k, payload: server))
        case .staleWrite(let server):
            if equalsIgnoringServerStamped(local: local, server: server, kind: k.kind) {
                // Self-conflict suppression: our prior write landed.
                await state.clear(k)
                await apply(.upserted(k, payload: server))
            } else {
                let payload = try encode(local, kind: k.kind)
                let serverVersion = versionOf(server, kind: k.kind)
                await state.recordRejected(k, RejectedDraft(upsertOf: k, payload: payload, serverVersion: serverVersion))
                await state.clear(k)
                await apply(.conflict(k, server: server, rejectedLocal: local))
            }
        }
    }

    // MARK: - Receipt upload state machine

    private var pendingTickets: [UUID: RemoteGroupsRepository.ReceiptUploadTicket] = [:]

    private func pushReceipt(key k: EntityKey, local: ReceiptDrainLocal) async throws {
        let step = await state.receiptStep(for: k.id)
        switch step {
        case .metadataPending: try await pushReceiptMetadata(key: k, local: local)
        case .bytesPending:    try await pushReceiptBytes(key: k, local: local)
        case .finalizePending: try await pushReceiptFinalize(key: k, local: local)
        }
    }

    private func pushReceiptMetadata(key k: EntityKey, local: ReceiptDrainLocal) async throws {
        let ticket: RemoteGroupsRepository.ReceiptUploadTicket
        do {
            ticket = try await remote.pushReceiptMetadata(
                expenseID: local.expenseID,
                receiptID: local.receipt.id,
                contentType: local.receipt.contentType,
                byteSize: local.receipt.byteSize
            )
        } catch let err as APIError {
            if case .server(_, _, let status, let reason) = err {
                switch status {
                case 403:
                    await state.clear(k)
                    await apply(.permissionDenied(k, action: .upsert))
                    return
                case 404:
                    return
                case 422:
                    await state.clear(k)
                    await apply(.receiptRejected(k, reason: reason))
                    return
                default:
                    throw err
                }
            }
            throw err
        }
        pendingTickets[k.id] = ticket
        await state.setReceiptStep(.bytesPending, for: k.id)
        try await pushReceiptBytes(key: k, local: local)
    }

    private func pushReceiptBytes(key k: EntityKey, local: ReceiptDrainLocal) async throws {
        // App kill between metadata and bytes loses the ticket; re-POST gets a
        // fresh presign (idempotent on receipt_id).
        guard let ticket = pendingTickets[k.id] else {
            await state.setReceiptStep(.metadataPending, for: k.id)
            return
        }
        let fileURL = ReceiptStore.default().url(for: local.receipt.id)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Bytes are gone — unrecoverable. Drop the dirty key, surface event
            // so AppStore removes the model row.
            pendingTickets.removeValue(forKey: k.id)
            await state.clear(k)
            await apply(.receiptFileMissing(k))
            return
        }
        do {
            try await remote.pushReceiptBytes(
                to: ticket.uploadURL,
                headers: ticket.headers,
                fileURL: fileURL
            )
        } catch let err as APIError {
            if case .server(_, _, let status, _) = err, status == 403 {
                // Presign expired / signature invalid — redo POST.
                pendingTickets.removeValue(forKey: k.id)
                await state.setReceiptStep(.metadataPending, for: k.id)
                return
            }
            throw err
        }
        pendingTickets.removeValue(forKey: k.id)
        await state.setReceiptStep(.finalizePending, for: k.id)
        try await pushReceiptFinalize(key: k, local: local)
    }

    private func pushReceiptFinalize(key k: EntityKey, local: ReceiptDrainLocal) async throws {
        do {
            try await remote.pushReceiptFinalize(receiptID: local.receipt.id)
        } catch let err as APIError {
            if case .server(_, _, let status, let reason) = err, status == 422 {
                if reason == "object_missing" || reason == "byte_size_mismatch" {
                    // Upload corrupted — redo the whole flow.
                    await state.setReceiptStep(.metadataPending, for: k.id)
                    return
                }
            }
            throw err
        }
        await state.clear(k)   // also drops receiptSteps[k.id] via clear's .receipt branch
        await apply(.upserted(k, payload: local.receipt))
    }

    private func drainDelete(_ k: EntityKey, version: Int) async throws {
        let outcome: MutationOutcome<Void>
        switch k.kind {
        case .group:   outcome = try await remote.deleteGroupVersioned(id: k.id, ifMatchVersion: version)
        case .expense: outcome = try await remote.deleteExpenseVersioned(id: k.id, in: k.groupID, ifMatchVersion: version)
        case .payment: outcome = try await remote.deletePaymentVersioned(id: k.id, in: k.groupID, ifMatchVersion: version)
        case .member:  outcome = try await remote.deleteMemberVersioned(id: k.id, in: k.groupID, ifMatchVersion: version)
        case .receipt:
            do {
                try await remote.deleteReceiptRemote(receiptID: k.id)
                await state.clear(k)
                await apply(.deleted(k))
            } catch let err as APIError {
                if case .server(_, _, let status, _) = err {
                    switch status {
                    case 403:
                        // Server says current user is neither uploader nor host.
                        // Clear the tombstone so the next group refresh re-inserts
                        // the receipt locally — restoring server-side truth.
                        await state.clear(k)
                        await apply(.permissionDenied(k, action: .delete))
                        return
                    case 404:
                        // Already gone on the server. Agree.
                        await state.clear(k)
                        await apply(.deleted(k))
                        return
                    default:
                        throw err   // 5xx etc → drain loop's outer catch handles retry
                    }
                }
                throw err
            }
            return
        }
        switch outcome {
        case .applied:
            await state.clear(k)
            await apply(.deleted(k))
        case .staleWrite:
            // Server returned its current entity in the 409 envelope. The
            // RemoteGroupsRepository's deleteVersioned methods strip the body and
            // return `.staleWrite(())` — to surface the server entity back to the
            // user we'd need to re-decode currentRaw. For now, treat as plain
            // conflict and let the user re-confirm; refresh will pick up the
            // server's current state.
            await state.clear(k)
            await apply(.conflict(k, server: nil, rejectedLocal: nil))
        }
    }

    // MARK: - Helpers

    private func mapOutcome<T>(_ o: MutationOutcome<T>) -> MutationOutcome<Any> {
        switch o {
        case .applied(let v):    return .applied(v as Any)
        case .staleWrite(let v): return .staleWrite(v as Any)
        }
    }

    private func equalsIgnoringServerStamped(local: Any, server: Any, kind: EntityKind) -> Bool {
        switch kind {
        case .group:
            var l = local as! ExpenseGroup; var s = server as! ExpenseGroup
            l.version = 0; s.version = 0
            l.updatedAt = .distantPast; s.updatedAt = .distantPast
            return l == s
        case .expense:
            var l = local as! Expense; var s = server as! Expense
            l.version = 0; s.version = 0
            l.updatedAt = .distantPast; s.updatedAt = .distantPast
            return l == s
        case .payment:
            var l = local as! Payment; var s = server as! Payment
            l.version = 0; s.version = 0
            l.updatedAt = .distantPast; s.updatedAt = .distantPast
            return l == s
        case .member:
            var l = local as! Member; var s = server as! Member
            l.version = 0; s.version = 0
            l.updatedAt = .distantPast; s.updatedAt = .distantPast
            return l == s
        case .receipt:
            return false   // Unused for receipts; conflict path doesn't run for them.
        }
    }

    private func encode(_ local: Any, kind: EntityKind) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        switch kind {
        case .group:   return try enc.encode(local as! ExpenseGroup)
        case .expense: return try enc.encode(local as! Expense)
        case .payment: return try enc.encode(local as! Payment)
        case .member:  return try enc.encode(local as! Member)
        case .receipt:
            return Data()   // Unused for receipts; .receipt path doesn't reach this helper.
        }
    }

    private func versionOf(_ entity: Any, kind: EntityKind) -> Int {
        switch kind {
        case .group:   return (entity as! ExpenseGroup).version
        case .expense: return (entity as! Expense).version
        case .payment: return (entity as! Payment).version
        case .member:  return (entity as! Member).version
        case .receipt:
            return 0   // Receipts have no version on the server.
        }
    }
}

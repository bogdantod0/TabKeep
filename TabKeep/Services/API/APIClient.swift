import Foundation

actor APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var onUpgradeRequired: (@Sendable (String) -> Void)?

    init(baseURL: URL,
         session: URLSession = .shared,
         onUpgradeRequired: (@Sendable (String) -> Void)? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.onUpgradeRequired = onUpgradeRequired

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            // ISO8601DateFormatter isn't Sendable, so it can't be captured
            // by a @Sendable closure — build fresh ones inside each decode.
            // JSONDecoder.dateDecodingStrategy.custom is invoked
            // synchronously per date field; the allocation cost is
            // negligible vs. the network call that precedes it.
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = withFrac.date(from: str) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let d = plain.date(from: str) { return d }
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Bad date \(str)")
        }
        self.decoder = dec
    }

    func setUpgradeCallback(_ cb: @escaping @Sendable (String) -> Void) {
        self.onUpgradeRequired = cb
    }

    // MARK: - No auth

    func registerDevice(deviceID: String, name: String, emoji: String, apnsToken: String?) async throws -> SessionDTO {
        struct Body: Encodable {
            let device_id: String
            let name: String
            let emoji: String
            let apns_token: String?
        }
        return try await request("POST", "api/v1/devices",
                                 body: Body(device_id: deviceID, name: name, emoji: emoji, apns_token: apnsToken),
                                 token: nil)
    }

    func signIn(provider: AuthProvider, idToken: String, deviceID: String,
                name: String?, emoji: String?, apnsToken: String?,
                token: String?) async throws -> SessionDTO {
        struct Body: Encodable {
            let provider: String
            let id_token: String
            let device_id: String
            let name: String?
            let emoji: String?
            let apns_token: String?
        }
        // `token` is the device's existing anonymous bearer when present. The
        // backend's sign_in skips `authenticate!` but still resolves
        // `current_device` from the Authorization header — without it,
        // `ensure_anonymous_device` mints a fresh user and orphans the
        // anonymous user's memberships (e.g., a group joined via invite
        // immediately before sign-in disappears with a "you were removed"
        // banner).
        return try await request("POST", "api/v1/auth/sign_in",
                                 body: Body(provider: provider.rawValue, id_token: idToken,
                                            device_id: deviceID, name: name, emoji: emoji, apns_token: apnsToken),
                                 token: token)
    }

    // MARK: - Bearer required

    func me(token: String) async throws -> MeResponseDTO {
        try await request("GET", "api/v1/me", body: Optional<Empty>.none, token: token)
    }

    func updateMe(token: String, displayName: String?, emoji: String?, apnsToken: String?) async throws -> MeResponseDTO {
        struct Body: Encodable {
            let display_name: String?
            let emoji: String?
            let apns_token: String?
        }
        return try await request("PATCH", "api/v1/me",
                                 body: Body(display_name: displayName, emoji: emoji, apns_token: apnsToken),
                                 token: token)
    }

    func linkProvider(token: String, provider: AuthProvider, idToken: String) async throws -> SessionDTO {
        struct Body: Encodable {
            let provider: String
            let id_token: String
        }
        return try await request("POST", "api/v1/auth/link",
                                 body: Body(provider: provider.rawValue, id_token: idToken),
                                 token: token)
    }

    /// DELETE /api/v1/me
    /// Hard-deletes the server-side user account (Apple guideline 5.1.1(v)
    /// compliance). Backend refuses with 422 `account_has_owned_groups`
    /// when the user still owns groups with other live members.
    func deleteMe(token: String) async throws {
        let _: EmptyResponse = try await request("DELETE", "api/v1/me",
                                                 body: Optional<Empty>.none, token: token,
                                                 expectsBody: false)
    }

    func signOut(token: String) async throws {
        let _: EmptyResponse = try await request("DELETE", "api/v1/devices/current",
                                                 body: Optional<Empty>.none, token: token,
                                                 expectsBody: false)
    }

    // MARK: - Groups

    func listGroups(token: String) async throws -> [GroupDTO] {
        // Backend returns {"data":[...], "next_cursor":...}.
        // TODO: paginate via next_cursor when group counts exceed default page size.
        struct Wrapper: Decodable {
            let data: [GroupDTO]
        }
        let wrapper: Wrapper = try await request("GET", "api/v1/groups",
                                                 body: Optional<Empty>.none, token: token)
        return wrapper.data
    }

    func getGroup(token: String, id: UUID) async throws -> GroupDTO {
        try await request("GET", "api/v1/groups/\(id.uuidString.lowercased())",
                          body: Optional<Empty>.none, token: token)
    }

    // MARK: - Invites

    /// POST /api/v1/groups/:group_id/invites — host only.
    /// Idempotent on the per-call key; the server caches the response for 24h.
    func createInvite(token: String,
                      groupID: UUID,
                      idempotencyKey: String) async throws -> InviteCreateResponse {
        try await request(
            "POST",
            "api/v1/groups/\(groupID.uuidString.lowercased())/invites",
            body: Optional<Empty>.none,
            token: token,
            idempotencyKey: idempotencyKey
        )
    }

    /// GET /api/v1/invites/:token/preview — no auth required (token is the auth).
    func previewInvite(rawToken: String) async throws -> InvitePreviewResponse {
        let escaped = rawToken.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rawToken
        return try await request(
            "GET",
            "api/v1/invites/\(escaped)/preview",
            body: Optional<Empty>.none,
            token: nil
        )
    }

    /// POST /api/v1/invites/:token/accept — any authenticated device.
    /// Idempotent on (token, current_user) server-side; we still pass an
    /// Idempotency-Key so transport retries don't double-fire.
    func acceptInvite(token: String,
                      rawToken: String,
                      idempotencyKey: String) async throws -> GroupDTO {
        let escaped = rawToken.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rawToken
        struct AcceptResponse: Decodable { let group: GroupDTO }
        let response: AcceptResponse = try await request(
            "POST",
            "api/v1/invites/\(escaped)/accept",
            body: Optional<Empty>.none,
            token: token,
            idempotencyKey: idempotencyKey
        )
        return response.group
    }

    // MARK: - PUT-as-upsert (Phase 3 sync)

    func putGroup(token: String, id: UUID, body: GroupUpsertDTO) async throws -> GroupDTO {
        try await request("PUT", "api/v1/groups/\(id.uuidString.lowercased())",
                          body: body, token: token)
    }

    func putExpense(token: String, id: UUID, body: ExpenseUpsertDTO) async throws -> ExpenseDTO {
        try await request("PUT", "api/v1/expenses/\(id.uuidString.lowercased())",
                          body: body, token: token)
    }

    func putPayment(token: String, id: UUID, body: PaymentUpsertDTO) async throws -> PaymentDTO {
        try await request("PUT", "api/v1/payments/\(id.uuidString.lowercased())",
                          body: body, token: token)
    }

    func putMembership(token: String, id: UUID, body: MembershipUpsertDTO) async throws -> MembershipDTO {
        try await request("PUT", "api/v1/memberships/\(id.uuidString.lowercased())",
                          body: body, token: token)
    }

    // MARK: - Receipts

    /// POST /api/v1/expenses/:expense_id/receipts.
    /// Server is idempotent on receipt_id (with_idempotency block).
    func createReceipt(
        token: String,
        expenseID: UUID,
        id: UUID,
        contentType: String,
        byteSize: Int64
    ) async throws -> ReceiptCreateResponseDTO {
        let body = ReceiptCreateRequestDTO(
            receiptID: id,
            contentType: contentType,
            byteSize: byteSize
        )
        return try await request(
            "POST",
            "api/v1/expenses/\(expenseID.uuidString.lowercased())/receipts",
            body: body,
            token: token,
            idempotencyKey: id.uuidString.lowercased()
        )
    }

    /// Streams the JPEG bytes from `fileURL` to the presigned S3 PUT URL.
    /// Does NOT route through `request(...)` — the presign IS the auth, so
    /// no bearer header is added. Uses `session.upload(for:fromFile:)`
    /// to stream from disk rather than load the whole file into memory.
    ///
    /// Throws APIError.server(code: ..., status: 403, reason: nil) when
    /// the presigned URL has expired (TTL = 5 min) or the signature is
    /// invalid. Drainer pattern-matches on status == 403 to reset the
    /// receipt step to .metadataPending and re-request a fresh presign.
    func putReceiptBytes(to url: URL, headers: [String: String], fileURL: URL) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await session.upload(for: req, fromFile: fileURL)
        } catch let err as URLError {
            throw APIError.transport(err)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unexpected(status: 0, bodyPreview: "non-http response from S3 PUT")
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.server(
                code: http.statusCode == 403 ? "signature_invalid" : "s3_error",
                message: "S3 PUT failed",
                status: http.statusCode,
                reason: nil
            )
        }
    }

    /// POST /api/v1/receipts/:id/finalize. Server returns 204 on success;
    /// 422 with reason "object_missing" or "byte_size_mismatch" surfaces
    /// via APIError.server.reason for the drainer to reset on.
    func finalizeReceipt(token: String, id: UUID) async throws {
        let _: EmptyResponse = try await request(
            "POST",
            "api/v1/receipts/\(id.uuidString.lowercased())/finalize",
            body: Optional<Empty>.none,
            token: token,
            expectsBody: false
        )
    }

    /// DELETE /api/v1/receipts/:id. Server returns 204 on success; 403
    /// when the current user isn't uploader/host; 404 when already gone.
    func deleteReceipt(token: String, id: UUID) async throws {
        let _: EmptyResponse = try await request(
            "DELETE",
            "api/v1/receipts/\(id.uuidString.lowercased())",
            body: Optional<Empty>.none,
            token: token,
            expectsBody: false
        )
    }

    /// GET /api/v1/receipts/:id — returns the presigned GET URL for
    /// the underlying S3 object.
    func getReceiptDownloadURL(token: String, id: UUID) async throws -> URL {
        struct Envelope: Decodable { let downloadURL: URL; enum CodingKeys: String, CodingKey { case downloadURL = "download_url" } }
        let env: Envelope = try await request(
            "GET",
            "api/v1/receipts/\(id.uuidString.lowercased())",
            body: Optional<Empty>.none,
            token: token
        )
        return env.downloadURL
    }

    // MARK: - DELETE with If-Match-Version (Phase 3 sync)

    func deleteGroupV2(token: String, id: UUID, ifMatchVersion: Int) async throws {
        let _: EmptyResponse = try await request(
            "DELETE", "api/v1/groups/\(id.uuidString.lowercased())",
            body: Optional<Empty>.none, token: token, expectsBody: false,
            extraHeaders: ["If-Match-Version": String(ifMatchVersion)]
        )
    }

    func deleteExpenseV2(token: String, id: UUID, ifMatchVersion: Int) async throws {
        let _: EmptyResponse = try await request(
            "DELETE", "api/v1/expenses/\(id.uuidString.lowercased())",
            body: Optional<Empty>.none, token: token, expectsBody: false,
            extraHeaders: ["If-Match-Version": String(ifMatchVersion)]
        )
    }

    func deletePaymentV2(token: String, id: UUID, ifMatchVersion: Int) async throws {
        let _: EmptyResponse = try await request(
            "DELETE", "api/v1/payments/\(id.uuidString.lowercased())",
            body: Optional<Empty>.none, token: token, expectsBody: false,
            extraHeaders: ["If-Match-Version": String(ifMatchVersion)]
        )
    }

    func deleteMembershipV2(token: String, id: UUID, ifMatchVersion: Int) async throws {
        let _: EmptyResponse = try await request(
            "DELETE", "api/v1/memberships/\(id.uuidString.lowercased())",
            body: Optional<Empty>.none, token: token, expectsBody: false,
            extraHeaders: ["If-Match-Version": String(ifMatchVersion)]
        )
    }

    #if DEBUG
    struct DebugPushResponse: Decodable {
        let recipients: Int?
        let attempted: Int?
        let succeeded: Int?
        let failed: Int?
        let results: [DebugPushResult]?
        let error: String?
    }

    struct DebugPushResult: Decodable {
        let device_id: String
        let status: String
        let apns_status: Int?
        let apns_reason: String?
        let error: String?
    }

    func triggerTestPush(token: String, groupID: UUID) async throws -> DebugPushResponse {
        try await request(
            "POST",
            "api/v1/debug/groups/\(groupID.uuidString.lowercased())/test_push",
            body: Optional<Empty>.none, token: token
        )
    }
    #endif

    // MARK: - Private

    private struct Empty: Encodable {}
    private struct EmptyResponse: Decodable {}
    private struct ErrorEnvelope: Decodable {
        struct E: Decodable {
            let code: String
            let message: String
            let details: Details?
            struct Details: Decodable { let reason: String? }
        }
        let error: E
    }

    private struct StaleWriteDetails: Decodable {
        let current: AnyJSON
    }

    private struct AnyJSON: Decodable {
        let raw: Data
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            // Re-encode the JSON value at this key back to bytes so the caller
            // can decode it into a typed DTO.
            if let v = try? container.decode(JSONValue.self) {
                self.raw = try JSONEncoder().encode(v)
            } else {
                self.raw = Data()
            }
        }
    }

    private enum JSONValue: Codable {
        case string(String)
        case number(Decimal)
        case bool(Bool)
        case null
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let v = try? c.decode(Bool.self) { self = .bool(v); return }
            if let v = try? c.decode(Decimal.self) { self = .number(v); return }
            if let v = try? c.decode(String.self) { self = .string(v); return }
            if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
            if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown JSON value")
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }
    }

    private struct StaleWriteEnvelope: Decodable {
        struct E: Decodable {
            let code: String
            let message: String
            let details: StaleWriteDetails
        }
        let error: E
    }

    private func request<Body: Encodable, Response: Decodable>(
        _ method: String,
        _ path: String,
        body: Body?,
        token: String?,
        idempotencyKey: String? = nil,
        expectsBody: Bool = true,
        extraHeaders: [String: String] = [:]
    ) async throws -> Response {
        var url = baseURL
        url.append(path: path)

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        req.setValue(appVersion, forHTTPHeaderField: "X-Client-Version")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let idempotencyKey { req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        if let body, !(body is Empty) {
            req.httpBody = try encoder.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let err as URLError {
            throw APIError.transport(err)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.unexpected(status: 0, bodyPreview: "no http response")
        }

        if (200..<300).contains(http.statusCode) {
            if !expectsBody || data.isEmpty {
                if let empty = EmptyResponse() as? Response { return empty }
                throw APIError.unexpected(status: http.statusCode, bodyPreview: "empty body but Response != EmptyResponse")
            }
            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                throw APIError.decoding(String(describing: error))
            }
        }

        // Stale-write 409: parse and surface the server's current state separately.
        if http.statusCode == 409,
           let env = try? decoder.decode(StaleWriteEnvelope.self, from: data),
           env.error.code == "stale_write" {
            throw APIError.staleWrite(currentRaw: env.error.details.current.raw)
        }

        // 426 Upgrade Required: the server's forced-update gate has rejected this build.
        if http.statusCode == 426 {
            let minimum = (try? decoder.decode(UpgradeRequiredEnvelope.self, from: data))?.error.details?.minimum ?? "unknown"
            onUpgradeRequired?(minimum)
            throw APIError.upgradeRequired(minimum: minimum)
        }

        // Generic error envelope.
        if let env = try? decoder.decode(ErrorEnvelope.self, from: data) {
            throw APIError.server(
                code: env.error.code,
                message: env.error.message,
                status: http.statusCode,
                reason: env.error.details?.reason
            )
        }

        let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
        throw APIError.unexpected(status: http.statusCode, bodyPreview: preview)
    }
}

private struct UpgradeRequiredEnvelope: Decodable {
    struct Inner: Decodable {
        struct Details: Decodable { let minimum: String? }
        let details: Details?
    }
    let error: Inner
}

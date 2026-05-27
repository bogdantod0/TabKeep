import Foundation
import Observation
import OSLog

private let authLog = Logger(subsystem: "com.example.tabkeep", category: "auth")

@Observable
@MainActor
final class AuthSession {
    enum State: Equatable {
        case loading
        case anonymous
        case signedIn(UserDTO, providers: [String], deviceID: UUID)
    }

    private(set) var state: State = .loading
    private(set) var lastError: APIError?

    /// Tracks the in-flight `bootstrap()` call. `registerAnonymousDevice`
    /// awaits this before doing its own work so an invite tap arriving
    /// during `.loading` doesn't race bootstrap and clobber its `state`
    /// writes (e.g. demoting a returning Apple/Google user to anonymous
    /// providers locally until the next `me` refresh).
    private var bootstrapTask: Task<Void, Never>?

    private let api: APIClient
    private let keychain: KeychainStore
    private let deviceIdentity: DeviceIdentityStore
    private let userProfileProvider: () -> User
    /// Snapshots the most recent APNs token (if any) so register-device /
    /// sign-in requests can carry `apns_token` in the body — closes the
    /// window where a new device row would otherwise exist on the server
    /// without a token until the next PATCH /me lands.
    private let apnsTokenProvider: () -> String?
    /// Invoked after a successful register / sign-in that carried an
    /// apns_token in the body. PushService uses this to mark the token
    /// as uploaded and skip the redundant follow-up PATCH.
    private let apnsTokenAcknowledged: (String) -> Void
    private let onSignOut: (@Sendable () async -> Void)?
    private let onSignIn: (@Sendable () async -> Void)?
    /// Invoked whenever a fresh `UserDTO` arrives from the server (sign-in,
    /// bootstrap, scene-active refresh, or profile PATCH). Lets AppStore
    /// reconcile the local `User` (UserDefaults) with the server's canonical
    /// profile. Server is the source of truth once signed in.
    private let onServerProfile: (@Sendable (UserDTO) async -> Void)?

    init(api: APIClient,
         keychain: KeychainStore,
         deviceIdentity: DeviceIdentityStore,
         userProfileProvider: @escaping () -> User,
         apnsTokenProvider: @escaping () -> String? = { nil },
         apnsTokenAcknowledged: @escaping (String) -> Void = { _ in },
         onSignOut: (@Sendable () async -> Void)? = nil,
         onSignIn: (@Sendable () async -> Void)? = nil,
         onServerProfile: (@Sendable (UserDTO) async -> Void)? = nil) {
        self.api = api
        self.keychain = keychain
        self.deviceIdentity = deviceIdentity
        self.userProfileProvider = userProfileProvider
        self.apnsTokenProvider = apnsTokenProvider
        self.apnsTokenAcknowledged = apnsTokenAcknowledged
        self.onSignOut = onSignOut
        self.onSignIn = onSignIn
        self.onServerProfile = onServerProfile
    }

    /// PATCH /me with the given fields. Used by Settings when the user
    /// edits their display name or emoji. Returns the server's
    /// canonicalized response so the caller can adopt any normalization
    /// (whitespace trim, default emoji, etc.).
    func updateProfile(displayName: String?, emoji: String?) async throws -> UserDTO {
        guard let token = try? keychain.loadToken() else {
            throw APIError.server(code: "auth_required", message: "Not signed in", status: 401, reason: nil)
        }
        let response = try await api.updateMe(
            token: token,
            displayName: displayName,
            emoji: emoji,
            apnsToken: nil
        )
        // Reflect the canonicalized profile in `state` and notify AppStore.
        let providers: [String]
        if case .signedIn(_, let p, _) = state { providers = p } else { providers = [] }
        self.state = .signedIn(response.user, providers: providers, deviceID: response.device.id)
        await onServerProfile?(response.user)
        return response.user
    }

    #if DEBUG
    /// DEBUG-only per-device outcome inside a `TestPushResult.results` array.
    struct TestPushDeviceResult {
        let deviceID: String
        let status: String
        let apnsStatus: Int?
        let apnsReason: String?
        let error: String?
    }

    /// DEBUG-only result for `triggerTestPush`. Carries the per-device
    /// breakdown the backend returns: `attempted` / `succeeded` / `failed`
    /// counts plus a `results` array with `apnsStatus` / `apnsReason` for
    /// each failure. `error` is the backend's coarse reason for the
    /// no-recipients case (`no_other_members` / `no_apns_token`).
    struct TestPushResult {
        let recipients: Int?
        let attempted: Int?
        let succeeded: Int?
        let failed: Int?
        let results: [TestPushDeviceResult]?
        let error: String?
    }

    /// DEBUG-only: hit the dev-mounted backend endpoint that pushes a
    /// synthetic notification to every *other* member's APNs-registered
    /// device in the given group. Mirrors what SendPushJob would do for a
    /// real entity change. The caller never receives the push themselves.
    func triggerTestPush(groupID: UUID) async throws -> TestPushResult {
        guard let token = try? keychain.loadToken() else {
            throw APIError.server(code: "auth_required", message: "Not signed in", status: 401, reason: nil)
        }
        let response = try await api.triggerTestPush(token: token, groupID: groupID)
        return TestPushResult(
            recipients: response.recipients,
            attempted:  response.attempted,
            succeeded:  response.succeeded,
            failed:     response.failed,
            results:    response.results?.map {
                TestPushDeviceResult(
                    deviceID:   $0.device_id,
                    status:     $0.status,
                    apnsStatus: $0.apns_status,
                    apnsReason: $0.apns_reason,
                    error:      $0.error
                )
            },
            error: response.error
        )
    }
    #endif

    /// PATCH /me with just the APNs token. Called by `PushService` after
    /// iOS hands us a fresh device token via the AppDelegate.
    ///
    /// Returns `true` iff the PATCH actually ran. Returns `false` (no
    /// throw) when there is no keychain bearer to authenticate with —
    /// the caller is expected to retain the token and retry once a
    /// bearer is available (typically after `registerAnonymousDevice`
    /// or OIDC sign-in via the `onSignIn` nudge).
    @discardableResult
    func uploadAPNsToken(_ apnsToken: String) async throws -> Bool {
        guard let token = try? keychain.loadToken() else { return false }
        let response = try await api.updateMe(
            token: token,
            displayName: nil,
            emoji: nil,
            apnsToken: apnsToken
        )
        let providers: [String]
        if case .signedIn(_, let p, _) = state { providers = p } else { providers = [] }
        self.state = .signedIn(response.user, providers: providers, deviceID: response.device.id)
        return true
    }

    /// Called once at app launch from `TabKeepApp.task`. Re-entrant calls
    /// (e.g., the invite flow awaiting in-flight bootstrap) share the
    /// same underlying Task — bootstrap's network call only runs once.
    func bootstrap() async {
        if let existing = bootstrapTask {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            await self.runBootstrap()
        }
        bootstrapTask = task
        await task.value
    }

    private func runBootstrap() async {
        self.lastError = nil
        let token: String?
        do {
            token = try keychain.loadToken()
        } catch {
            self.state = .anonymous
            return
        }
        guard let token else {
            self.state = .anonymous
            return
        }
        await refresh(usingCachedToken: token)
    }

    /// Registers the device on the backend without linking a provider.
    /// On success the local state transitions to `.signedIn` (no provider
    /// listed in `providers: []`) and the device token is stored in keychain.
    /// Used by the invite create flow when the host taps "Invite people" while
    /// anonymous — the backend needs an authenticated device to mint invites
    /// and host a group.
    ///
    /// No-op when `state` is already `.signedIn`.
    func registerAnonymousDevice() async throws {
        // If bootstrap is still in flight (warm invite tap during cold
        // start), wait for it to settle. Without this, both calls race
        // their `state` writes — a returning OIDC user can end up locally
        // marked as anonymous-with-no-providers until the next `me` PATCH.
        if let bootstrapTask, case .loading = state {
            await bootstrapTask.value
        }
        if case .signedIn = state { return }
        self.lastError = nil
        let profile = userProfileProvider()
        let pendingAPNs = apnsTokenProvider()
        let session: SessionDTO
        do {
            session = try await api.registerDevice(
                deviceID:  deviceIdentity.deviceID().uuidString,
                name:      profile.name.isEmpty ? "Me" : profile.name,
                emoji:     profile.emoji.isEmpty ? Member.defaultEmoji : profile.emoji,
                apnsToken: pendingAPNs
            )
        } catch let err as APIError {
            self.lastError = err
            authLog.error("anon_register failed code=\(Self.codeOrKind(of: err), privacy: .public)")
            throw err
        }
        try keychain.store(token: session.deviceToken)
        self.state = .signedIn(session.user, providers: session.linkedProviders, deviceID: deviceIdentity.deviceID())
        self.lastError = nil
        if let t = pendingAPNs { apnsTokenAcknowledged(t) }
        authLog.info("anon_register success")
        await onServerProfile?(session.user)
        await onSignIn?()
    }

    /// Called from `.onChange(of: scenePhase)` when the scene becomes active.
    /// No-ops while bootstrap is still in flight (`state == .loading`) so the
    /// two paths don't race their `/me` calls and clobber each other's writes.
    func refresh() async {
        if case .loading = state { return }
        self.lastError = nil
        let token: String?
        do { token = try keychain.loadToken() } catch { token = nil }
        guard let token else { return }
        await refresh(usingCachedToken: token)
    }

    private func refresh(usingCachedToken token: String) async {
        do {
            let me = try await api.me(token: token)
            self.state = .signedIn(me.user, providers: me.linkedProviders, deviceID: me.device.id)
            self.lastError = nil
            await onServerProfile?(me.user)
        } catch let err as APIError {
            self.lastError = err
            if case .server(let code, _, _, _) = err, code == "auth_invalid" || code == "auth_required" {
                try? keychain.clear()
                self.state = .anonymous
                authLog.error("refresh auth_invalid: signed out locally")
                return
            }
            // Transport / unknown — keep last good state if we had one, else anonymous.
            if case .signedIn = self.state {
                authLog.error("refresh transient_error code=\(String(describing: err), privacy: .public); keeping signedIn")
            } else {
                self.state = .anonymous
            }
        } catch {
            self.lastError = .unexpected(status: 0, bodyPreview: String(describing: error))
            self.state = .anonymous
        }
    }

    func signIn(with provider: AuthProvider,
                idTokenProvider: () async throws -> String) async throws {
        self.lastError = nil
        let idToken: String
        do {
            idToken = try await idTokenProvider()
        } catch let auth as AuthError {
            if case .cancelled = auth { return }
            throw auth
        }

        let profile = userProfileProvider()
        let pendingAPNs = apnsTokenProvider()
        // Forward the existing bearer (anonymous registration earlier in the
        // session, e.g. during invite accept) so the backend's
        // `ensure_anonymous_device` resolves the same device row and
        // `AccountLinker` upgrades the anon user in place. Without this the
        // server mints a fresh user, the prior anonymous user's memberships
        // are orphaned, and `reconcileOnSignIn` evicts the just-joined group
        // with a "removed" banner.
        let existingToken = (try? keychain.loadToken()) ?? nil
        let session: SessionDTO
        do {
            session = try await api.signIn(
                provider:   provider,
                idToken:    idToken,
                deviceID:   deviceIdentity.deviceID().uuidString,
                name:       profile.name.isEmpty ? nil : profile.name,
                emoji:      profile.emoji,
                apnsToken:  pendingAPNs,
                token:      existingToken
            )
        } catch let err as APIError {
            self.lastError = err
            authLog.error("sign_in failed provider=\(provider.rawValue, privacy: .public) code=\(Self.codeOrKind(of: err), privacy: .public)")
            throw err
        }

        try keychain.store(token: session.deviceToken)
        self.state = .signedIn(session.user, providers: session.linkedProviders, deviceID: deviceIdentity.deviceID())
        self.lastError = nil
        if let t = pendingAPNs { apnsTokenAcknowledged(t) }
        authLog.info("sign_in success provider=\(provider.rawValue, privacy: .public)")
        await onServerProfile?(session.user)
        await onSignIn?()
    }

    func linkProvider(_ provider: AuthProvider,
                      idTokenProvider: () async throws -> String) async throws {
        self.lastError = nil
        guard let token = try keychain.loadToken() else {
            // Token gone but state still says signedIn — self-heal so the UI re-renders.
            self.state = .anonymous
            authLog.error("link aborted: keychain missing token; state -> anonymous")
            throw APIError.server(code: "auth_required", message: "Not signed in", status: 401, reason: nil)
        }
        let idToken: String
        do {
            idToken = try await idTokenProvider()
        } catch let auth as AuthError {
            if case .cancelled = auth { return }
            throw auth
        }
        let session: SessionDTO
        do {
            session = try await api.linkProvider(token: token, provider: provider, idToken: idToken)
        } catch let err as APIError {
            self.lastError = err
            authLog.error("link failed provider=\(provider.rawValue, privacy: .public) code=\(Self.codeOrKind(of: err), privacy: .public)")
            throw err
        }
        try keychain.store(token: session.deviceToken)
        self.state = .signedIn(session.user, providers: session.linkedProviders, deviceID: deviceIdentity.deviceID())
        self.lastError = nil
        authLog.info("link success provider=\(provider.rawValue, privacy: .public)")
        await onServerProfile?(session.user)
    }

    /// Hard-deletes the user's server-side account (Apple compliance)
    /// and wipes local state, mirroring the post-sign-out cleanup.
    /// Re-throws the server's APIError when the backend refuses (e.g.
    /// `validation_failed` with `reason: "account_has_owned_groups"`)
    /// so the caller can surface a tailored message.
    func deleteAccount() async throws {
        self.lastError = nil
        guard let token = try? keychain.loadToken() else {
            // No server-side account locally. Treat as already-deleted —
            // wipe through the same sign-out cleanup path.
            await onSignOut?()
            try? keychain.clear()
            self.state = .anonymous
            return
        }
        do {
            try await api.deleteMe(token: token)
        } catch let err as APIError {
            self.lastError = err
            authLog.error("delete_account failed code=\(Self.codeOrKind(of: err), privacy: .public)")
            throw err
        }
        await onSignOut?()
        try? keychain.clear()
        self.state = .anonymous
        self.lastError = nil
        authLog.info("delete_account success")
    }

    func signOut() async throws {
        self.lastError = nil
        guard let token = try? keychain.loadToken() else {
            self.state = .anonymous
            return
        }
        // onSignOut runs FIRST so AppStore.dropAll's drainer pass can deliver
        // pending tombstones/upserts using the still-valid token. If we
        // revoked the token server-side first, those drains would fail with
        // auth_invalid and the next sign-in would resurrect locally-deleted
        // groups via listShared.
        await onSignOut?()
        do {
            try await api.signOut(token: token)
        } catch let err as APIError {
            // If the server says auth_invalid we're already effectively signed out.
            if case .server(let code, _, _, _) = err, code == "auth_invalid" || code == "auth_required" {
                // fall through to local cleanup
            } else {
                self.lastError = err
                authLog.error("sign_out failed code=\(Self.codeOrKind(of: err), privacy: .public)")
                throw err
            }
        }
        try? keychain.clear()
        self.state = .anonymous
        self.lastError = nil
        authLog.info("sign_out success")
    }

    private static func codeOrKind(of err: APIError) -> String {
        switch err {
        case .transport: return "transport"
        case .server(let code, _, _, _): return code
        case .staleWrite: return "stale_write"
        case .decoding: return "decoding"
        case .unexpected: return "unexpected"
        case .upgradeRequired: return "upgrade_required"
        }
    }
}

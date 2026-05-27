import Foundation
import Grovs

@MainActor
final class InviteService {
    private let api: APIClient
    private let tokenProvider: @Sendable () async -> String?
    private let sdkKey: String

    /// Token captured from the deferred deep link during `bootstrap()`,
    /// consumed by AppStore's post-onboarding tick. Cleared by the consumer.
    private(set) var capturedDeferredToken: String?

    /// Tokens AppStore has resolved to a terminal state (accepted, or
    /// definitively dead). The Grovs SDK keeps `lastReceivedPayload`
    /// sticky for the lifetime of the install, so without this gate
    /// every foreground would re-yield the same token and re-trigger
    /// the join flow / "Joined" toast.
    ///
    /// Backed by UserDefaults as a bounded LRU. The Grovs payload survives
    /// process restarts, so without persistence every cold launch after a
    /// successful join would re-replay the same (now-dead) token and flash
    /// "This invite link is no longer valid".
    private var handledTokens: [String] = []
    private static let handledTokensKey = "InviteService.handledTokens"
    private static let handledTokensCap = 32

    init(api: APIClient,
         tokenProvider: @escaping @Sendable () async -> String?,
         sdkKey: String) {
        self.api = api
        self.tokenProvider = tokenProvider
        self.sdkKey = sdkKey
        self.handledTokens = (UserDefaults.standard.array(forKey: Self.handledTokensKey) as? [String]) ?? []
        Grovs.configure(APIKey: sdkKey, useTestEnvironment: false, delegate: nil)
    }

    /// Called by AppStore once a token has reached a terminal state:
    /// accept succeeded, or the server reported the link as revoked/
    /// expired/not found. After this neither `bootstrap()` nor
    /// `handleIncomingURL` will resurface the token, even though the
    /// SDK still has it cached.
    func markHandled(_ token: String) {
        handledTokens.removeAll { $0 == token }
        handledTokens.append(token)
        if handledTokens.count > Self.handledTokensCap {
            handledTokens.removeFirst(handledTokens.count - Self.handledTokensCap)
        }
        UserDefaults.standard.set(handledTokens, forKey: Self.handledTokensKey)
        if capturedDeferredToken == token {
            capturedDeferredToken = nil
        }
    }

    private func isHandled(_ token: String) -> Bool {
        handledTokens.contains(token)
    }

    // MARK: - Host side

    /// Mints an invite via the backend, then wraps the raw token in a grovs
    /// short link. Returns the share-ready URL.
    func mintLink(for groupID: UUID) async throws -> URL {
        guard let bearer = await tokenProvider() else {
            throw APIError.server(code: "auth_required", message: "Not signed in", status: 401, reason: nil)
        }
        let response = try await api.createInvite(
            token: bearer,
            groupID: groupID,
            idempotencyKey: UUID().uuidString
        )
        let payload: [String: Any] = ["type": "invite", "token": response.token]
        let url: URL? = await withCheckedContinuation { continuation in
            Grovs.generateLink(
                title: nil,
                subtitle: nil,
                imageURL: nil,
                data: payload,
                tags: nil,
                customRedirects: nil,
                showPreviewiOS: nil,
                showPreviewAndroid: nil,
                trackingCampaign: nil,
                trackingSource: nil,
                trackingMedium: nil
            ) { generated in
                continuation.resume(returning: generated)
            }
        }
        guard let url else {
            throw APIError.server(code: "internal", message: "Failed to generate Grovs link", status: 500, reason: nil)
        }
        return url
    }

    // MARK: - Recipient side

    func preview(rawToken: String) async throws -> InvitePreviewResponse {
        try await api.previewInvite(rawToken: rawToken)
    }

    /// Accepts the invite and returns the full server group payload.
    func accept(rawToken: String) async throws -> GroupDTO {
        guard let bearer = await tokenProvider() else {
            throw APIError.server(code: "auth_required", message: "Not signed in", status: 401, reason: nil)
        }
        return try await api.acceptInvite(
            token: bearer,
            rawToken: rawToken,
            idempotencyKey: UUID().uuidString
        )
    }

    // MARK: - Deep-link plumbing

    /// Polls the grovs SDK for any deferred deep link captured during install.
    /// Sets `capturedDeferredToken` if found.
    func bootstrap() async {
        // Pull whatever deferred-deep-link payload the SDK captured during install.
        // We use the polling helper (instead of GrovsDelegate) because AppStore
        // is the single consumer and the cold-path replay happens on a known
        // tick after onboarding completes.
        let payload: [String: Any]? = await withCheckedContinuation { continuation in
            Grovs.lastReceivedPayload { payload in
                continuation.resume(returning: payload)
            }
        }
        guard
            let payload,
            let type = payload["type"] as? String, type == "invite",
            let token = payload["token"] as? String
        else { return }
        guard !isHandled(token) else { return }
        capturedDeferredToken = token
    }

    /// Called from `TabKeepApp.onOpenURL`. Hands the URL to the Grovs SDK
    /// and returns the extracted invite token if present, or nil if the URL
    /// isn't a grovs invite link.
    func handleIncomingURL(_ url: URL) async -> String? {
        // Hand to the SDK first. If the SDK declines (non-grovs URL), bail
        // before reading lastReceivedPayload — otherwise we could return a
        // stale token captured from a prior deep link.
        let recognized = Grovs.handleAppDelegate(open: url, options: [:])
        guard recognized else { return nil }

        let payload: [String: Any]? = await withCheckedContinuation { continuation in
            Grovs.lastReceivedPayload { dictionary in
                continuation.resume(returning: dictionary)
            }
        }
        guard
            let payload,
            let type = payload["type"] as? String, type == "invite",
            let token = payload["token"] as? String
        else { return nil }
        guard !isHandled(token) else { return nil }
        return token
    }
}

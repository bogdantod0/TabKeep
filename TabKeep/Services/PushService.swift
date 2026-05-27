import Foundation
import UIKit
import UserNotifications
import OSLog

private let pushLog = Logger(subsystem: "com.example.tabkeep", category: "push")

/// Owns the iOS-side push lifecycle: permission prompt, registration,
/// and shipping the resulting APNs token up to the backend.
///
/// The AppDelegate is intentionally dumb — it just forwards APNs callbacks
/// to closures. Those closures invoke this service, which in turn talks to
/// `AuthSession` for the PATCH /me with the apns_token.
@MainActor
final class PushService {
    private let authSession: AuthSession

    /// Latest hex token we successfully uploaded. Lets us skip a redundant
    /// PATCH when iOS hands us the same token a second time in a session.
    private var lastUploadedTokenHex: String?

    /// Latest hex token iOS handed us that we *could not* upload yet
    /// (no keychain bearer at the time, or the network call threw).
    /// Replayed by `flushPendingToken()` once the device has a bearer —
    /// typically right after anon-registration or OIDC sign-in.
    private var pendingTokenHex: String?

    /// Most recent token iOS handed us, regardless of upload state. Read
    /// by AuthSession so sign-in / device-register requests can carry the
    /// apns_token in the body — server then stores it atomically with the
    /// new device row instead of waiting for a follow-up PATCH /me.
    private(set) var currentTokenHex: String?

    init(authSession: AuthSession) {
        self.authSession = authSession
    }

    /// Ask for permission (the system prompt only shows the first time),
    /// then register for remote notifications if granted. Idempotent and
    /// safe to call repeatedly — iOS dedupes prompts internally.
    ///
    /// Called once per launch from `TabKeepApp.task` after the
    /// auth bootstrap completes, so we always have a session token to
    /// authenticate the eventual `uploadAPNsToken` call.
    func requestAuthorizationAndRegister() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            pushLog.info("notification_permission granted=\(granted, privacy: .public)")
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            pushLog.error("notification_permission_failed err=\(String(describing: error), privacy: .public)")
        }
    }

    /// Re-register silently if the user has previously authorized. Picks
    /// up rotated tokens on each launch without re-prompting.
    func reregisterIfAuthorized() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default:
            break
        }
    }

    /// Handle a fresh APNs token from the AppDelegate. Skips the network
    /// call when nothing has changed. When the upload can't run yet
    /// (no keychain bearer) or transiently fails, the token is parked on
    /// `pendingTokenHex` so `flushPendingToken()` can retry.
    func handleAPNsToken(_ tokenHex: String) async {
        currentTokenHex = tokenHex
        if tokenHex == lastUploadedTokenHex { return }
        do {
            let uploaded = try await authSession.uploadAPNsToken(tokenHex)
            if uploaded {
                lastUploadedTokenHex = tokenHex
                pendingTokenHex = nil
                pushLog.info("apns_token_uploaded len=\(tokenHex.count, privacy: .public)")
            } else {
                pendingTokenHex = tokenHex
                pushLog.info("apns_token_pending len=\(tokenHex.count, privacy: .public) reason=no_bearer")
            }
        } catch {
            pendingTokenHex = tokenHex
            pushLog.error("apns_token_upload_failed err=\(String(describing: error), privacy: .public)")
        }
    }

    /// Replay the most recent token iOS gave us if it was never uploaded.
    /// Called by `AuthSession.onSignIn` after anon-registration or OIDC
    /// sign-in. No-op when nothing is pending or the pending value already
    /// matches what we last uploaded.
    func flushPendingToken() async {
        guard let pending = pendingTokenHex, pending != lastUploadedTokenHex else { return }
        await handleAPNsToken(pending)
    }

    /// Record a token as already uploaded — called by `AuthSession` when
    /// it attached `apns_token` to a sign-in / register-device body and
    /// the request succeeded. Server stored the token as part of that
    /// transaction, so a follow-up PATCH /me would be redundant.
    func markUploaded(_ tokenHex: String) {
        lastUploadedTokenHex = tokenHex
        if pendingTokenHex == tokenHex { pendingTokenHex = nil }
    }
}

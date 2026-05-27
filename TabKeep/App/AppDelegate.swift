import UIKit
import UserNotifications
import OSLog
import Grovs
import FirebaseCore
import FirebaseAnalytics

private let pushLog = Logger(subsystem: "com.example.tabkeep", category: "push")

/// SwiftUI doesn't expose `UIApplicationDelegate` lifecycle hooks directly,
/// so we bridge via `@UIApplicationDelegateAdaptor`. The delegate stays
/// dumb on purpose: it forwards APNs callbacks to closures that
/// `TabKeepApp.init` wires up against PushService / AppStore / AuthSession.
///
/// Callbacks are static so the App layer can install them at construction
/// time without holding a reference to the adapter-created instance.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Hex-encoded APNs token (lowercased). Called every time iOS hands the
    /// app a token — once per launch when authorized, and again whenever
    /// the token rotates.
    static var onAPNsTokenReceived: (@Sendable (String) async -> Void)?

    /// Silent push (`content-available: 1`). Trigger a `foregroundRefresh`
    /// so the user sees the new expense/payment without re-opening the app.
    static var onSilentPushReceived: (@Sendable () async -> Void)?

    /// User tapped a visible notification. Carries enough info to deep-link
    /// to the relevant group / expense / payment.
    static var onNotificationTap: (@Sendable (PushDeepLink) async -> Void)?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Must run before any code that emits analytics events, so we do it
        // first in the launch path. Reads SplitBill/GoogleService-Info.plist.
        FirebaseApp.configure()
        // Force-enable Analytics collection. The plist's IS_ANALYTICS_ENABLED
        // flag is set at download time and can come down false even when the
        // Firebase project has GA4 linked (regen lag, stream-vs-property
        // attachment issues). This runtime opt-in supersedes the plist value
        // and persists across launches via UserDefaults.
        Analytics.setAnalyticsCollectionEnabled(true)
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        pushLog.info("apns_register_success token_len=\(hex.count, privacy: .public)")
        Task { await Self.onAPNsTokenReceived?(hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        pushLog.error("apns_register_failed err=\(String(describing: error), privacy: .public)")
    }

    /// Universal-link delivery path. iOS routes taps on the Grovs
    /// associated domains (see `TabKeep.entitlements`) via NSUserActivity,
    /// not via `application(_:open:)`. Without forwarding the activity to
    /// Grovs the SDK never sees the payload and the invite-accept flow
    /// silently drops on already-installed devices. The scheme/openURL
    /// path (the Grovs URL scheme in `Info.plist` / `project.yml`) is
    /// still handled in SwiftUI via
    /// `.onOpenURL` → `InviteService.handleIncomingURL`.
    func application(_ application: UIApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        return Grovs.handleAppDelegate(continue: userActivity, restorationHandler: restorationHandler)
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        if let eid = Self.eventID(from: userInfo), Self.sawRecentSyncEvent(eid) {
            pushLog.info("silent_push_skipped_duplicate event_id=\(eid, privacy: .public)")
            completionHandler(.noData)
            return
        }
        Task {
            await Self.onSilentPushReceived?()
            completionHandler(.newData)
        }
    }

    // MARK: - Push idempotency
    //
    // Backend stamps each silent sync push with a `sync_id` (UUID); visible
    // pushes carry a `type` + entity id (`expense_id` / `payment_id` /
    // `membership_id`). Both can redeliver — APNs network blips, app
    // relaunches, or the backend fanning out across multiple device rows
    // pointing at the same physical device.
    //
    // Two separate LRUs because `willPresent` and `didReceiveRemoteNotification`
    // both fire for a single push that carries `alert` + `content-available:1`,
    // and sharing one LRU would have the first handler suppress the second
    // for the same delivery. Each handler dedupes its own redeliveries.
    private static let recentEventIDsLock = NSLock()
    private static var recentSyncEventIDs: [String] = []     // gates didReceiveRemoteNotification
    private static var recentBannerEventIDs: [String] = []   // gates willPresent
    private static let maxRecentEventIDs = 32

    private static func sawRecentSyncEvent(_ id: String) -> Bool {
        recordEvent(id, in: &recentSyncEventIDs)
    }

    private static func sawRecentBannerEvent(_ id: String) -> Bool {
        recordEvent(id, in: &recentBannerEventIDs)
    }

    private static func recordEvent(_ id: String, in list: inout [String]) -> Bool {
        recentEventIDsLock.lock()
        defer { recentEventIDsLock.unlock() }
        if list.contains(id) { return true }
        list.append(id)
        if list.count > maxRecentEventIDs {
            list.removeFirst(list.count - maxRecentEventIDs)
        }
        return false
    }

    /// Stable identity for a push so redeliveries can be suppressed. Prefers
    /// `sync_id` (stamped on silent sync pushes); falls back to
    /// `(type, entity_id)` for visible pushes, which is unique per logical
    /// event (one expense add = one expense_id, regardless of how many
    /// device rows the backend fans out to). Returns nil when no entity
    /// is named — in that case the caller falls through and the push is
    /// delivered/displayed normally.
    private static func eventID(from userInfo: [AnyHashable: Any]) -> String? {
        if let sid = userInfo["sync_id"] as? String { return "sync:\(sid)" }
        let type = (userInfo["type"] as? String) ?? ""
        switch type {
        case "expense":
            if let id = userInfo["expense_id"] as? String { return "expense:\(id)" }
        case "payment":
            if let id = userInfo["payment_id"] as? String { return "payment:\(id)" }
        case "membership":
            if let id = userInfo["membership_id"] as? String { return "membership:\(id)" }
        case "membership_removed":
            if let id = userInfo["membership_id"] as? String { return "membership_removed:\(id)" }
        case "group_deleted":
            if let id = userInfo["group_id"] as? String { return "group_deleted:\(id)" }
        default: break
        }
        return nil
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        if let eid = Self.eventID(from: userInfo), Self.sawRecentBannerEvent(eid) {
            // Same logical event already displayed in this session — happens
            // when APNs redelivers or the backend fans out to a stale extra
            // device row that resolves to the same physical device.
            pushLog.info("foreground_banner_skipped_duplicate event_id=\(eid, privacy: .public)")
            completionHandler([])
            return
        }
        // Show the banner + sound when the app is foregrounded — the silent
        // push handler already syncs the data, but the user still wants to
        // know something happened.
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let deepLink = PushDeepLink(userInfo: userInfo) {
            Task {
                await Self.onNotificationTap?(deepLink)
                completionHandler()
            }
        } else {
            completionHandler()
        }
    }
}

/// Decoded from the APNs custom payload set by
/// `PushNotificationComposer#compose` on the backend. The composer puts
/// `type`, `group_id`, and an entity-id at the root of the userInfo dict
/// (alongside the standard `aps` envelope), so we read them from there.
struct PushDeepLink: Sendable {
    enum Kind: Sendable {
        case expense(UUID)
        case payment(UUID)
        case membership(UUID)
        /// The host removed this user from `groupID`. The group is being
        /// (or has just been) evicted locally; the tap handler should
        /// open the app without trying to navigate to the gone group.
        case membershipRemoved(UUID)
        /// The host deleted the entire group. Same handling as
        /// `membershipRemoved` — no destination to navigate to.
        case groupDeleted
        case sync
    }

    let groupID: UUID
    let kind: Kind

    init?(userInfo: [AnyHashable: Any]) {
        guard let gidStr = userInfo["group_id"] as? String,
              let gid = UUID(uuidString: gidStr) else { return nil }
        self.groupID = gid

        let type = (userInfo["type"] as? String) ?? "sync"
        switch type {
        case "expense":
            if let s = userInfo["expense_id"] as? String, let id = UUID(uuidString: s) {
                self.kind = .expense(id)
            } else {
                self.kind = .sync
            }
        case "payment":
            if let s = userInfo["payment_id"] as? String, let id = UUID(uuidString: s) {
                self.kind = .payment(id)
            } else {
                self.kind = .sync
            }
        case "membership":
            if let s = userInfo["membership_id"] as? String, let id = UUID(uuidString: s) {
                self.kind = .membership(id)
            } else {
                self.kind = .sync
            }
        case "membership_removed":
            if let s = userInfo["membership_id"] as? String, let id = UUID(uuidString: s) {
                self.kind = .membershipRemoved(id)
            } else {
                self.kind = .sync
            }
        case "group_deleted":
            self.kind = .groupDeleted
        default:
            self.kind = .sync
        }
    }
}

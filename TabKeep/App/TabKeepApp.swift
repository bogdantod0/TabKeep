import SwiftUI
import GoogleSignIn

@main
struct TabKeepApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: AppStore
    @State private var authSession: AuthSession
    @State private var inviteService: InviteService
    @State private var pushService: PushService
    @AppStorage("hasOnboarded") private var hasOnboarded: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let persistence = JSONPersistence(fileURL: JSONPersistence.defaultURL())

        if ProcessInfo.processInfo.arguments.contains("--uitest-fresh-store") {
            try? FileManager.default.removeItem(at: JSONPersistence.defaultURL())
            try? FileManager.default.removeItem(at: SyncState.defaultURL())
            UserDefaults.standard.removeObject(forKey: AppStore.appearanceKey)
        }

        let api = APIClient(baseURL: APIBaseURL.resolved())
        let keychain = KeychainStore()
        let tokenProvider: @Sendable () async -> String? = {
            (try? keychain.loadToken()) ?? nil
        }
        let local = LocalGroupsRepository(persistence: persistence)
        // storeBox needs to exist before `remote` so the membership-upsert
        // body builder can read the current user's match-key. It's
        // populated below once `store` is constructed.
        let storeBox = AppStoreHolder()
        let remote = RemoteGroupsRepository(
            api: api,
            tokenProvider: tokenProvider,
            userIdentityProvider: { [storeBox] in
                await MainActor.run {
                    let user = storeBox.store?.user
                    let key = user?.matchKey
                    return (matchKey: (key?.isEmpty == false) ? key : nil,
                            serverID: user?.serverID)
                }
            }
        )
        let hybrid = HybridGroupsRepository(local: local, remote: remote)

        // Holder lets AppStore's isSignedIn closure observe AuthSession even
        // though AuthSession is constructed after AppStore.
        let sessionBox = AuthSessionHolder()

        // PushService is constructed after AuthSession, but AuthSession's
        // onSignIn closure needs to nudge it so the freshly-authenticated
        // device uploads its APNs token (uploadAPNsToken no-ops without a
        // keychain token, so a device that registered for pushes pre-sign-in
        // would otherwise never reach the backend).
        let pushBox = PushServiceHolder()

        let inviteService = InviteService(
            api: api,
            tokenProvider: tokenProvider,
            sdkKey: Bundle.main.object(forInfoDictionaryKey: "GrovsSDKKey") as? String ?? ""
        )

        let syncState = SyncState(fileURL: SyncState.defaultURL())

        // CRITICAL: capture sessionBox/storeBox STRONGLY in these closures.
        // sessionBox/storeBox are local-scope and would otherwise be
        // deallocated when init() returns — every weak ref through them
        // would go nil, making isSignedIn() always return false and silently
        // disabling the drainer. The holders themselves are tiny (one weak
        // var each) and there are no retain cycles since session/store are
        // held strongly by the @State props elsewhere.
        let syncDrainer = SyncDrainer(
            state: syncState,
            remote: remote,
            entityProvider: { [storeBox] key in
                await MainActor.run { storeBox.store?.lookup(entityKey: key) }
            },
            apply: { [storeBox] event in
                await MainActor.run { storeBox.store?.apply(serverEvent: event) }
            },
            isSignedIn: { [sessionBox] in
                // Drainer gate is "do we have a bearer to talk to the server."
                // Both anonymous and signed-in devices have one (tokenProvider
                // reads it from Keychain). Block only the .loading window
                // before bootstrap resolves.
                guard let s = sessionBox.session else { return false }
                let state = await MainActor.run { s.state }
                switch state {
                case .loading: return false
                case .anonymous, .signedIn: return true
                }
            }
        )

        // Receipt downloads route through the remote repo's presigned-GET helper.
        Task {
            await ReceiptDownloader.shared.configure { id in
                try await remote.receiptDownloadURL(receiptID: id)
            }
        }

        let store = AppStore(
            repository: hybrid,
            syncState: syncState,
            syncDrainer: syncDrainer,
            fxService: FrankfurterFXService(),
            isSignedIn: { [sessionBox] in
                // AppStore expects a sync closure. AuthSession.state is
                // @MainActor; callers of this closure are also on the main
                // actor (AppStore reads it from view-driven paths), so
                // `assumeIsolated` reads safely without hopping.
                guard let s = sessionBox.session else { return false }
                let state = MainActor.assumeIsolated { s.state }
                if case .signedIn = state { return true }
                return false
            },
            inviteService: inviteService,
            anonRegister: { [sessionBox] in
                guard let s = sessionBox.session else {
                    throw APIError.server(code: "auth_required", message: "AuthSession not initialized", status: 500, reason: nil)
                }
                try await s.registerAnonymousDevice()
            },
            requestPushPermission: { [pushBox] in
                await pushBox.service?.requestAuthorizationAndRegister()
            }
        )
        storeBox.store = store
        _store = State(initialValue: store)
        _inviteService = State(initialValue: inviteService)

        Task { [storeBox] in
            await api.setUpgradeCallback { minimum in
                Task { @MainActor in storeBox.store?.setUpgradeRequired(minimum) }
            }
        }

        let deviceIdentity = DeviceIdentityStore()
        let session = AuthSession(api: api,
                                  keychain: keychain,
                                  deviceIdentity: deviceIdentity,
                                  userProfileProvider: { [weak store] in
                                      store?.user ?? User.empty
                                  },
                                  apnsTokenProvider: { [pushBox] in
                                      // Lets registerDevice / signIn attach apns_token
                                      // atomically with the new device row, instead of
                                      // relying on a follow-up PATCH /me to fill it in.
                                      pushBox.service?.currentTokenHex
                                  },
                                  apnsTokenAcknowledged: { [pushBox] t in
                                      pushBox.service?.markUploaded(t)
                                  },
                                  onSignOut: { [weak store] in
                                      await store?.dropAll()
                                  },
                                  onSignIn: { [weak store, pushBox] in
                                      await store?.reconcileOnSignIn()
                                      // Flush a pending APNs token (deterministic) instead of
                                      // round-tripping through iOS via reregisterIfAuthorized,
                                      // which is not guaranteed to re-vend the same token. The
                                      // foreground re-register path on .onChange(of: scenePhase)
                                      // still handles rotated tokens.
                                      await pushBox.service?.flushPendingToken()
                                  },
                                  onServerProfile: { [weak store] dto in
                                      await store?.applyServerProfile(dto)
                                  })
        sessionBox.session = session

        // Profile push closure: AppStore.setProfile / applyServerProfile call
        // this when they need to PATCH /me. Returns the server's canonical
        // response, or nil if the call failed.
        store.profileSyncer = { [weak session] name, emoji in
            guard let session else { return nil }
            return try? await session.updateProfile(displayName: name, emoji: emoji)
        }
        _authSession = State(initialValue: session)

        let pushService = PushService(authSession: session)
        pushBox.service = pushService
        _pushService = State(initialValue: pushService)

        // Wire AppDelegate's static callbacks to the services we just
        // constructed. `@UIApplicationDelegateAdaptor` instantiates the
        // delegate independently, so callbacks-by-static is the simplest
        // way to bridge — and these are set once at app init, then read
        // from the main-thread UIApplicationDelegate methods, so no
        // isolation concern.
        AppDelegate.onAPNsTokenReceived = { [weak pushService] tokenHex in
            await pushService?.handleAPNsToken(tokenHex)
        }
        AppDelegate.onSilentPushReceived = { [weak store] in
            await store?.foregroundRefresh()
        }
        AppDelegate.onNotificationTap = { [weak store, weak session] deepLink in
            guard let store else { return }
            // Cold launch: this tap handler fires before WindowGroup's
            // .task has reached authSession.bootstrap(), so AuthSession
            // is still .loading and refresh()/foregroundRefresh() would
            // short-circuit at their `isSignedInProvider()` guards. Await
            // bootstrap (idempotent — the .task's later call shares this
            // same in-flight Task) so the API calls below actually run.
            await session?.bootstrap()
            // group.deleted / membership.deleted: the target group has
            // been destroyed or we were kicked. Skip the targeted refresh
            // (it would 404 or evict us, with a banner flash) and run a
            // full foregroundRefresh to settle local state. Don't set
            // pendingNavigation — there's nothing to navigate to.
            switch deepLink.kind {
            case .groupDeleted, .membershipRemoved:
                await store.foregroundRefresh()
                return
            default:
                break
            }
            // Pull the target group from the server before setting
            // pendingNavigation. The companion silent push is not a
            // reliable pre-sync — iOS throttles silent delivery to
            // backgrounded/killed apps, and even when it lands it races
            // foregroundRefresh's bounded-concurrency loop. Without this
            // targeted refresh, EditExpenseView can render before the
            // referenced expense has landed in local state and show
            // "Expense not found".
            await store.refresh(groupID: deepLink.groupID, force: true)
            await MainActor.run {
                // Entity-specific routes (expense/payment/membership) aren't
                // all wired in GroupsRoute yet — pendingNavigation falls
                // back to the parent group for payment/membership the same
                // way openDraftReview does.
                switch deepLink.kind {
                case .expense(let id):
                    store.pendingNavigation = .expense(groupID: deepLink.groupID, expenseID: id)
                case .groupDeleted, .membershipRemoved:
                    // Unreachable — handled in the early-return above.
                    break
                default:
                    store.pendingNavigation = .group(id: deepLink.groupID)
                }
            }
        }

        if let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
           !clientID.isEmpty,
           !clientID.contains("REPLACE_ME") {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasOnboarded {
                    RootTabView()
                } else {
                    OnboardingView()
                }
            }
            .environment(store)
            .environment(authSession)
            .preferredColorScheme(store.appearance.colorScheme)
            .animation(.snappy, value: hasOnboarded)
            .fullScreenCover(item: Binding(
                get: { store.upgradeRequiredMinimum.map { UpgradeIdentifier(minimum: $0) } },
                set: { _ in /* non-dismissable */ }
            )) { idx in
                UpgradeRequiredView(minimum: idx.minimum)
            }
            .task {
                await store.retryPendingRates()
                await store.reconcilePreSyncReceipts()
                await authSession.bootstrap()
                // Kick the drainer before inviteService.bootstrap() — the
                // Grovs SDK's `lastReceivedPayload` callback can hang
                // indefinitely (e.g., URL-scheme config mismatch), and
                // we don't want a UI-flow dependency to block server sync.
                if case .signedIn = authSession.state {
                    await store.reconcileOnSignIn()    // kicks drainer internally
                } else {
                    await store.syncDrainer.kick()     // no-op when signed-out
                }
                // Invite token capture is best-effort; run in a detached
                // task so a hung Grovs callback doesn't stall the rest of
                // this bootstrap chain (foregroundRefresh, push register).
                Task {
                    await inviteService.bootstrap()
                    if let captured = inviteService.capturedDeferredToken {
                        await MainActor.run { store.pendingInviteToken = captured }
                    }
                }
                await store.foregroundRefresh()
                // Push: only ask post-onboarding so users see the rationale
                // first (the splash screens make clear what this app shares
                // with whom). After the initial prompt, every cold launch
                // silently re-registers so rotated APNs tokens get re-uploaded.
                if hasOnboarded {
                    await pushService.requestAuthorizationAndRegister()
                }
            }
            .onOpenURL { url in
                Task {
                    if let token = await inviteService.handleIncomingURL(url) {
                        await store.handleIncomingInvite(token: token, isColdPath: false)
                        return
                    }
                    _ = await MainActor.run { GIDSignIn.sharedInstance.handle(url) }
                }
            }
            .onChange(of: hasOnboarded) { _, newValue in
                // The .task above only fires once at WindowGroup appearance,
                // when hasOnboarded is still false on a brand-new install.
                // Fire the prompt the moment onboarding completes so the
                // user sees it in this session, not the next launch. iOS
                // dedupes the system prompt internally, so a stray second
                // call is a cheap no-op.
                if newValue {
                    Task { await pushService.requestAuthorizationAndRegister() }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task {
                        await store.retryPendingRates()
                        await store.reconcilePreSyncReceipts()
                        await authSession.refresh()
                        // Kick drainer before invite bootstrap so a hung
                        // Grovs callback doesn't stall sync (see .task).
                        if case .signedIn = authSession.state {
                            await store.reconcileOnSignIn()
                        } else {
                            await store.syncDrainer.kick()
                        }
                        Task {
                            await inviteService.bootstrap()
                            if let captured = inviteService.capturedDeferredToken {
                                await MainActor.run { store.pendingInviteToken = captured }
                            }
                        }
                        // Cold-path retry runs BEFORE foregroundRefresh.
                        // Order matters: a kicked user re-tapping an invite
                        // link on cold launch would otherwise see the
                        // "You were removed" banner flash (posted by
                        // foregroundRefresh's eviction pass) before the
                        // re-accept un-deletes their seat. RootTabView's
                        // .task only fires once on first mount; this is
                        // the recovery path for every subsequent foreground.
                        if hasOnboarded, let pending = store.pendingInviteToken {
                            await store.handleIncomingInvite(token: pending, isColdPath: true)
                        }
                        await store.foregroundRefresh()
                        // Silently re-register on every foreground in case
                        // the APNs token rotated — iOS won't re-prompt.
                        await pushService.reregisterIfAuthorized()
                    }
                }
            }
        }
    }
}


// `@unchecked Sendable` holders for late-binding @MainActor-bound services
// into @Sendable closures captured at App construction time. Writes to
// `session` / `store` / `service` happen once during TabKeepApp.init on
// the main actor, before any closure that reads them is ever invoked, so
// the weak ref is effectively read-only by the time it matters.
private final class AuthSessionHolder: @unchecked Sendable {
    weak var session: AuthSession?
}

private final class AppStoreHolder: @unchecked Sendable {
    weak var store: AppStore?
}

private final class PushServiceHolder: @unchecked Sendable {
    weak var service: PushService?
}

private struct UpgradeIdentifier: Identifiable {
    let id = UUID()
    let minimum: String
}

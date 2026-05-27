# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

The Xcode project is **generated** from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) and is `.gitignore`d. After changing `project.yml` or adding/removing source files, run:

```
xcodegen generate
```

Build the app (iPhone 17 simulator is the convention used throughout plans/specs):

```
xcodebuild -project TabKeep.xcodeproj -scheme TabKeep \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug build
```

There are **no test targets** in this project — they were intentionally removed (commit `a60cff4`). Verification is a clean `xcodebuild build` plus manual testing in the simulator. Do not recreate test targets without explicit user direction.

### UI testing launch argument

The app recognizes `--uitest-fresh-store` at launch (see `TabKeepApp.swift`) and wipes the on-disk JSON before `AppStore` loads. Use this when manually exercising flows from a clean slate.

## Architecture

iOS 17+, Swift 5.10, SwiftUI + `@Observable`. Single app target, folder-organized, no Swift packages. The app is a **local-first, server-synced** system: every mutation persists locally and synchronously through `AppStore`, and is mirrored to the Rails backend through a state-based outbox (`Sync/`).

### Layers and boundaries

- **`App/`** — `SplitBillApp` (root `@main`, wires `AppStore`/`AuthSession`/`PushService`/`InviteService`/`SyncDrainer` and runs `retryPendingRates` on launch + scene-active) and `AppDelegate` (APNs registration callbacks). The app's bootstrap lives here, not in views.
- **`Algorithm/`** — pure value-in/value-out logic. `BalanceCalculator`, `GreedyDebtSimplifier`, `DebtSimplifier`, `ActivityBuilder`, `CategoryTotals`, `StatisticsAggregator`, `Settlement`, `ActivityEvent`. **Must not import SwiftUI or reference `AppStore`.** This is what makes the balance, debt-simplification, and statistics claims testable in isolation and the invariant to preserve when extending these algorithms.
- **`Models/`** — `ExpenseGroup`, `Expense`, `Member`, `ReceiptAttachment`, `ActivityEntry`, `User`, `AppearancePreference`, `StatisticsRange`/`StatisticsSummary`. All `Codable`/`Hashable` value types keyed by `UUID`. `ExpenseGroup.Payment` is a nested member→member transfer (balance-affecting, distinct from a multi-payer expense's `ExpensePayment`). Referential integrity (`payerID`, `participantIDs`, `fromMemberID`/`toMemberID` belong to the same group) is **not** enforced by types — it is enforced at the `AppStore` mutation boundary.
- **`Store/AppStore.swift`** — `@Observable` single source of truth (~2500 lines). Owns: `groups`, `activityLog`, `pendingDeletion`, `defaultCurrencyCode`, `appearance`, `conflictBanners`, `drafts`, `activeEditingEntity`, `isRetryingPendingRates`, the invite-flow state (`pendingInviteToken`, `pendingInviteConfirm`, `inviteErrorBanner`, `lastJoinedGroupID`, `pendingGhostClaim`), and composes the `syncState`/`syncDrainer`. Views receive it via `@Environment(AppStore.self)`. **All mutations go through `AppStore` methods; views never mutate models directly.** Every mutation persists to disk synchronously via `GroupsPersistence` and marks affected entities dirty in `SyncState`.
- **`Store/JSONPersistence.swift`** — the production `GroupsPersistence`. The on-disk schema is versioned (currently **v19**) with explicit `VNWrapper` migration structs in the file. **Any change to `Expense`/`ExpenseGroup`/`Payment`/`Member`/`ActivityEntry` shape requires bumping `currentVersion` and adding a migration path** — breaking existing users' files is not acceptable. (Device-level settings like `appearance` are persisted to `UserDefaults`, not through this store.)
- **`Repositories/`** — `GroupsRepository` protocol + three implementations: `LocalGroupsRepository` (JSON only), `RemoteGroupsRepository` (Rails API), `HybridGroupsRepository` (local-first, schedules remote sync). Production uses the hybrid one.
- **`Sync/`** — `SyncState` (actor; tracks `dirty` set, `tombstones` for optimistic deletes, rejected `drafts` for conflicts; persisted to its own JSON file), `SyncDrainer` (actor; drains the queue, PUTs/DELETEs via `APIClient`, surfaces 409s as conflict banners), plus `EntityKey`, `RejectedDraft`, `ServerEvent`. Drain order matters: **upserts walk parents → children (group → members → expenses/payments); deletes walk children → parents.** Tombstones carry the entity version at delete time, so a stale "edit then delete" round-trip won't accidentally undelete on the server.
- **`Services/`** — split by concern:
  - `FXService` / `FrankfurterFXService` / `FXRateCache` / `FXRate` — currency conversion.
  - `Services/Auth/` — `AuthSession` (`@Observable` state machine), `AppleSignInCoordinator`, `GoogleSignInCoordinator`, `KeychainStore` (bearer token), `DeviceIdentityStore`.
  - `Services/API/` — `APIClient` (`actor` over `URLSession`), `APIError`, `DTO/` (the wire contract: `UserDTO`, `GroupDTO`, `PaymentDTO`, etc.).
  - `PushService` — APNs permission, registration, token upload.
  - `InviteService` — Grovs deep-link SDK wrapper for invite tokens.
- **`Views/`** — SwiftUI. `RootTabView` is the shell; feature views (incl. `DashboardView`, `OnboardingView`, `PostGroupCreationInviteView`, `UpgradeRequiredView`) live alongside it; reusable UI is in `Views/Components/` (with `Views/Components/Stats/` for the dashboard cards); navigation route enums in `Views/Routing/`.

### Money

Always `Decimal`, never `Double`. Amounts are stored in major units (e.g. dollars, not cents). `BalanceCalculator.splitAmount` does banker's rounding at 2 decimal places and assigns any residual cent to the first participant in ID-sorted order so splits are deterministic. `BalanceCalculator.balances` asserts the net sum is zero as a debug invariant — it factors in both expenses (with per-expense `payments` for multi-payer cases) and group-level recorded `Payment`s.

### Multi-currency / FX

An `Expense` carries its own `currencyCode` plus a snapshotted `exchangeRate` to the group's currency. `BalanceCalculator` multiplies `amount * exchangeRate` when computing balances — the algorithm itself is currency-agnostic.

If the FX fetch fails (offline, API down), the expense is still saved with `ratePending: true` and a rate of `1`. `AppStore.retryPendingRates()` re-fetches any pending rates and is wired to run on app launch and when the scene becomes active (see `SplitBillApp`). When editing an expense, the rate is re-fetched only if `currencyCode`, `date`, or `ratePending` changed.

### Auth & device identity

Every install has a server-side session — anonymous devices are registered via `AuthSession.registerDevice()` and get a bearer token, just like signed-in users. The state machine in `AuthSession` is:

- `.loading` — startup, before identity resolved.
- `.anonymous` — device-only; `DeviceIdentityStore` holds the device ID and Keychain holds the anon bearer.
- `.signedIn(user, providers, deviceID)` — Apple or Google sign-in completed; the server `UserDTO` is the source of truth for `displayName` / `emoji` from this point.

`AuthSession.onSignIn` is the post-sign-in fan-out — `PushService` listens to flush any pending APNs token (see push section), and `AppStore` listens to reconcile its local `user` against the server profile. Every `APIClient` call requires a bearer; calls made while `.loading` or before `registerDevice()` completes will no-op or fail loudly rather than silently dropping data.

### Sync model (state-based outbox)

Local writes are authoritative — they hit disk + UI immediately, then `SyncState` records each mutation as a dirty `EntityKey`. `SyncDrainer` reads from `SyncState.nextPending()` and pushes to the server. Two invariants matter:

1. **Order**: parents-before-children on upserts, children-before-parents on deletes. If you add a new entity type to sync, slot it into this ordering — getting it wrong causes referential-integrity rejections on the server.
2. **Conflicts**: a server 409 produces a `RejectedDraft` stored in `SyncState.drafts` and surfaced as a `ConflictBanner` in `AppStore`. The local mutation is **not** silently retried — the user resolves it.

### Push notifications

`PushService` owns APNs end-to-end: permission prompt, `registerForRemoteNotifications()`, and uploading the device token to the server via `APIClient`. The wrinkle is timing — APNs may hand us a token before we have a bearer, so the service tracks `pendingTokenHex` (offline-stored, replayed once auth is ready) separately from `lastUploadedTokenHex` (the value the server already knows, used to avoid redundant uploads). Permission is requested at two moments: end of onboarding (`OnboardingView`) and immediately after an invite-link accept (so the inviter can be notified). Do **not** prompt for permission on cold start.

### Invite links (Grovs)

`InviteService` wraps the Grovs SDK. Tokens arrive in two shapes:

- **Cold path** — app was not installed; Grovs captures the deferred token at first launch (`capturedDeferredToken`).
- **Warm path** — tap on an invite link in a running app; `handleIncomingURL()` consults Grovs for the token.

A token transitions through `pendingInviteToken` → `pendingInviteConfirm` (preview sheet) → server accept → optional `pendingGhostClaim` (when the joined group has ghost members the new user might want to claim instead of creating a fresh membership). `handledTokens` prevents a token from being re-processed on foregrounding. After a successful accept the user lands on the joined group and is offered the post-creation invite share sheet.

### Navigation

`RootTabView` owns:
- `selectedTab: BottomTabBar.Tab` — `.dashboard`, `.groups`, `.activity`, `.settings` (four tabs).
- `groupsPath: [GroupsRoute]` — drives the groups `NavigationStack`.
- `addSheet: AddSheet?` — resolved context-aware by `resolveAddSheet()` (returns `.addExpense(groupID)` when inside a group/expense route, `.createGroup` otherwise).
- invite-flow UX state (`postCreateInviteGroupID`) and group-list search state (`isSearchExpanded`, `searchText`).

`GroupsRoute` is the single `Hashable` enum that describes every pushable destination in the groups stack (currently `.group(id:)` and `.expense(groupID:, expenseID:)`). Adding a new screen under the groups tab means adding a case here and a matching `navigationDestination` branch in `RootTabView.tabContent`.

The tab bar auto-hides on the expense edit screen (see `isTabBarHidden`). Tapping the groups tab while already on it pops to root.

### Undo deletions

Deleting a group, expense, or recorded payment does **not** immediately discard data. `AppStore` puts a `PendingDeletion` on `pendingDeletion`; `UndoSnackbar` renders above the tab bar and either calls `undoPendingDeletion()` or `commitPendingDeletion()`. Any new delete commits the previous pending one first. Commit is what actually fires the sync delete — undo never reaches the network.

### Appearance (dark mode)

`AppStore.appearance: AppearancePreference` (`.system` / `.light` / `.dark`) drives `.preferredColorScheme()` at the root. **This preference is persisted to `UserDefaults` under `AppStore.appearanceKey`, not through `GroupsPersistence`** — it's a per-device UI setting, not user data. Don't migrate it through the JSON schema.

### Dashboard / statistics

The `.dashboard` tab renders `DashboardView`, which builds a `StatisticsSummary` for a `StatisticsRange` (`.week`, `.month`, `.quarter`, `.year`, `.custom(from, to)`) using `StatisticsAggregator` from the Algorithm layer. The cards in `Views/Components/Stats/` (`HeroTotalCard`, `TrendChartCard`, `CategoryDonutCard`, `BalanceRingCard`, `GroupBarsCard`, `CustomRangeSheet`) read from that summary — they never touch `AppStore.groups` directly. Statistics computation stays pure Algorithm, like balances.

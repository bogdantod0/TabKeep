# TabKeep

A local-first, server-synced iOS bill-splitting app — think Splitwise, built in SwiftUI for iOS 17+, with multi-currency expenses, multi-payer support, and Grovs-powered deferred deep-link invites.

Licensed under the [MIT License](LICENSE).

## Powered by Grovs

Invite flows are the connective tissue of any bill-splitting app — and TabKeep's are built on **[Grovs](https://grovs.io)**. Grovs handles:

- **Universal Links** — taps on `https://<your-grovs-domain>/<token>` route the user directly to the invite-accept screen, even from cold app launches.
- **Deferred deep linking** — if the recipient doesn't have TabKeep installed yet, Grovs preserves the invite token across the App Store install so the first launch lands on the group they were invited to. No lost invites.
- **Branded short links** — every invite URL uses the project's own short domain.
- **Cross-platform ready** — same SDK works for iOS, Android, and web.

The integration lives in `Services/InviteService.swift` (Grovs SDK wrapper) and the invite-flow state machine in `Store/AppStore.swift`. Without Grovs, every accept would require manual deep-link plumbing, AASA hosting, deferred-token storage at the OS level, and post-install token replay — all of which Grovs collapses into a single SDK call. If you fork this project, grab a free Grovs project at [grovs.io](https://grovs.io) and drop the SDK key into the config.

## Screenshots

App Store screenshots live in [`screenshots/framed/`](screenshots/framed) (iPhone) and [`screenshots/ipad/framed/`](screenshots/ipad/framed) (iPad).

## Highlights

- **Group expenses** with equal, exact-amount, and percentage splits
- **Multi-payer expenses** and standalone member-to-member payments — both are first-class and balance-affecting
- **Per-expense currency** with snapshotted FX rate; group totals roll up in the group's currency
- **Balance calculation + greedy debt simplification** as pure, deterministic algorithms (Decimal-only math, banker's rounding)
- **Activity feed and statistics dashboard** — week / month / quarter / year / custom range, with category breakdowns
- **Receipt photo attachments**, uploaded to the backend and lazily downloaded for offline viewing
- **Grovs-powered invite links** with deferred deep linking (see above)
- **Apple Sign-In and Google Sign-In**, with anonymous device sessions before the user signs in (so the app works fully offline from launch)
- **APNs push notifications** for group activity
- **Light / dark / system appearance**, undo for any deletion, optimistic-write sync with conflict-banner resolution

## Tech stack

| Layer | Choice |
|---|---|
| Language | Swift 5.10 |
| UI | SwiftUI + `@Observable` (no UIKit views) |
| Min iOS | 17.0 |
| Project | [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml` is the source of truth, `.xcodeproj` is generated and git-ignored |
| State | Single `@Observable` `AppStore` as the source of truth |
| Persistence | Versioned JSON on disk (schema v19, explicit migrations) |
| Sync | State-based outbox (`Sync/SyncState` actor + `SyncDrainer` actor); local-first writes, parents-before-children on upsert, children-before-parents on delete |
| Auth | Apple Sign-In (native), Google Sign-In ([GoogleSignIn-iOS](https://github.com/google/GoogleSignIn-iOS)), anonymous device bearer tokens |
| Push | APNs via `UNUserNotificationCenter` + custom upload to the backend |
| Deep links | **[Grovs](https://grovs.io)** — universal links + deferred deep linking |
| FX rates | [Frankfurter](https://www.frankfurter.app) (ECB-sourced, free public API) — snapshotted per expense and cached |
| Analytics | Firebase Analytics ([firebase-ios-sdk](https://github.com/firebase/firebase-ios-sdk)) |
| Backend | Rails (separate repository, not included here) |

Dependency management is via Swift Package Manager, declared in `project.yml`. No CocoaPods, no Carthage.

## Requirements

- macOS with Xcode 16 or newer
- iOS 17 simulator or device
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- An Apple Developer team for signing
- A Rails backend the iOS app talks to (separate repository, not included here)
- A free [Grovs](https://grovs.io) project for invite links
- A Firebase project for Analytics (optional — set up dummy values if you don't want analytics)
- A Google Cloud OAuth iOS client for Google Sign-In

## Setup — replace the placeholders

This repo ships with `REPLACE_ME_*` placeholders for every account-bound credential and identifier. You **must** replace them with your own values before the app will build, sign, or run end-to-end. Search for `REPLACE_ME_` across the tree to find every spot:

```sh
grep -r REPLACE_ME_ . --exclude-dir=.git --exclude-dir=build
```

### What each placeholder is

| Placeholder | File(s) | What to put there |
|---|---|---|
| `REPLACE_ME_TEAM_ID` | `project.yml` | Your Apple Developer Team ID (10-char, from `developer.apple.com` → Membership) |
| `com.example.tabkeep` | `project.yml`, `TabKeep/GoogleService-Info.plist` (BUNDLE_ID) | Your app's bundle identifier — must match across both files and your Apple Developer App ID |
| `REPLACE_ME_API_HOST` | `Config/Release.xcconfig` | Hostname of your deployed Rails backend (no scheme, no path) — e.g. `api.example.com`. Debug builds default to `localhost:3000`. |
| `REPLACE_ME_GROVS_SDK_KEY` | `Config/Debug.xcconfig`, `Config/Release.xcconfig` | Your [Grovs](https://grovs.io) project SDK key (used for deep-linked invites). A Release build with this placeholder unset fails fast via a pre-build script guard. |
| `REPLACE_ME_GROVS_DOMAIN` | `TabKeep/TabKeep.entitlements` | Your Grovs Universal Link host — e.g. `myapp.sqd.link`. Goes in the `applinks:` entry. |
| `REPLACE_ME_GROVS_URL_SCHEME` | `project.yml`, `TabKeep/Info.plist` | Your Grovs custom URL scheme (Grovs assigns one per project). Listed in `CFBundleURLTypes`. |
| `REPLACE_ME_GOOGLE_OAUTH_CLIENT_ID` | `Config/Shared.xcconfig` | The numeric prefix of your Google Cloud Console iOS OAuth client ID. The two lines build the full client ID + reversed client ID from this one value. |
| `REPLACE_ME_FIREBASE_API_KEY`, `REPLACE_ME_GCM_SENDER_ID`, `REPLACE_ME_FIREBASE_PROJECT_ID`, `REPLACE_ME_GOOGLE_APP_ID` | `TabKeep/GoogleService-Info.plist` | Easiest: download a fresh `GoogleService-Info.plist` from the Firebase console for your iOS app and replace the whole file. |

### Account/service setup checklist

1. **Apple Developer**: create an App ID with your bundle identifier and enable Sign in with Apple, Push Notifications, and Associated Domains capabilities.
2. **Rails backend**: deploy your own (the iOS app expects the REST shape defined by the DTOs in `TabKeep/Services/API/DTO/`).
3. **Firebase**: create a project, register an iOS app with your bundle ID, download the new `GoogleService-Info.plist` into `TabKeep/`.
4. **Google Cloud Console** (in the same Firebase project): create an OAuth 2.0 iOS Client ID for Google Sign-In, paste it into `Config/Shared.xcconfig`.
5. **Grovs**: create a project at [grovs.io](https://grovs.io), copy the SDK key into the xcconfigs, copy the Universal Link domain into the entitlements, copy the URL scheme into `project.yml` + `Info.plist`. Register your Apple Team ID + Bundle ID in the Grovs console so the Apple App Site Association file is served correctly.
6. **APNs**: upload your APNs Auth Key to whatever your backend uses to send pushes.

## Build & run

The Xcode project is generated from `project.yml` and is git-ignored. Generate it, then build:

```sh
xcodegen generate

xcodebuild -project TabKeep.xcodeproj -scheme TabKeep \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug build
```

Open `TabKeep.xcodeproj` in Xcode to run on a simulator or device. There are no automated tests — verification is a clean `xcodebuild build` plus manual exercise in the simulator.

A launch argument `--uitest-fresh-store` wipes the local JSON store before `AppStore` loads — useful for testing flows from a clean slate.

In `DEBUG` builds, `API_BASE_URL` can be overridden at runtime via `UserDefaults` key `api_base_url_override` (see `Services/API/APIBaseURL.swift`).

## Architecture

See [`CLAUDE.md`](CLAUDE.md) for the full architectural tour — layer boundaries, the state-based outbox sync model, multi-currency handling, auth state machine, invite flow, and the JSON persistence schema (currently v19).

Quick map:

- `App/` — `@main` entry point, `AppDelegate` for APNs + Grovs activity forwarding
- `Algorithm/` — pure value-in/value-out logic (balances, debt simplification, statistics)
- `Models/` — `Codable` value types
- `Store/AppStore.swift` — `@Observable` single source of truth, persisted via `JSONPersistence`
- `Repositories/` — local / remote / hybrid `GroupsRepository`
- `Sync/` — outbox state and drainer
- `Services/` — FX (Frankfurter), Auth (Apple/Google + Keychain), API client + DTOs, Push (APNs), **Invite (Grovs)**
- `Views/` — SwiftUI feature views and components

## License

[MIT](LICENSE).

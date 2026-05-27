# App Store screenshots

Framed, captioned marketing screenshots for the App Store listing.

| Set     | Final images        | Size        | App Store slot      |
|---------|---------------------|-------------|---------------------|
| iPhone  | `framed/`           | 1284 × 2778 | 6.5" / 6.7"         |
| iPad    | `ipad/framed/`      | 2064 × 2752 | 13" iPad            |

Upload the `framed/` images. `raw/` (and `ipad/raw/`) hold the unframed
simulator captures — intermediate only.

- `capture.sh` — installs the app on a simulator and captures each screen.
- `frame.py` — composites `raw/` → `framed/` with caption + device frame
  (needs Pillow: `pip3 install --user Pillow`).

## Regenerate

Capture relies on a launch-argument-gated **screenshot mode** that is *not*
committed (it's app code that must not ship). Restore it first — a
`ScreenshotPlan` / `DemoData` file in `TabKeep/App/` plus small hooks in
`TabKeepApp`, `RootTabView`, and `GroupDetailView` — see git history for the
last version. With `--screenshot <screen>` the app seeds deterministic demo
data, skips onboarding, disables sync, and routes straight to the target
screen (`dashboard`, `groups`, `groupDetail`, `editExpense`, `balances`,
`activity`). Strip it again once captures are done.

```sh
# 1. Build (Debug) after restoring screenshot mode
xcodebuild -project TabKeep.xcodeproj -scheme TabKeep \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug -derivedDataPath build/dd build

# 2. iPhone set
bash screenshots/capture.sh
python3 screenshots/frame.py

# 3. iPad set
SCREENSHOT_DEVICE="iPad Pro 13-inch (M4)" \
  SCREENSHOT_RAW="$PWD/screenshots/ipad/raw" bash screenshots/capture.sh
SHOT_W=2064 SHOT_H=2752 \
  SHOT_RAW="$PWD/screenshots/ipad/raw" \
  SHOT_OUT="$PWD/screenshots/ipad/framed" python3 screenshots/frame.py
```

## Device note

Capture runs on **iOS 18** simulators (iPhone 16 Pro Max, iPad Pro 13-inch M4)
— the iOS 26 runtime renders emoji as tofu, and every member/group avatar is an
emoji. Both devices match their App Store slots pixel-for-pixel. Override the
device with `SCREENSHOT_DEVICE`.

Give a freshly-booted simulator time to warm up — the first one or two cold
launches can screenshot blank before SwiftUI has drawn; just re-run those.

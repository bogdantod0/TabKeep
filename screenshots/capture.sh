#!/usr/bin/env bash
# Captures raw App Store screenshots from the TabKeep simulator build.
# The app must already be built (see README in this folder); this script
# installs it, launches each screen via the `--screenshot` arg, and captures.
#
# Env overrides:
#   SCREENSHOT_DEVICE  simulator device name (default: iPhone 16 Pro Max)
#   SCREENSHOT_RAW     output directory     (default: screenshots/raw)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/dd/Build/Products/Debug-iphonesimulator/TabKeep.app"
BUNDLE="com.example.tabkeep"
# Default is iPhone 16 Pro Max (6.9", 1320x2868). Its iOS 18 runtime renders
# emoji correctly — the iOS 26 runtime shows tofu for the emoji avatars, so
# pick an iOS-18 device. For the 13" iPad slot use "iPad Pro 13-inch (M4)".
DEVICE="${SCREENSHOT_DEVICE:-iPhone 16 Pro Max}"
RAW="${SCREENSHOT_RAW:-$ROOT/screenshots/raw}"

mkdir -p "$RAW"

[ -d "$APP" ] || { echo "App not found at $APP — build it first." >&2; exit 1; }

UDID=$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | grep -oiE '[0-9a-f-]{36}')
echo "Device: $DEVICE  ($UDID)"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID"
xcrun simctl ui "$UDID" appearance light
xcrun simctl install "$UDID" "$APP"
xcrun simctl status_bar "$UDID" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --operatorName "" || true

SCREENS=(dashboard groups groupDetail editExpense balances activity)
i=1
for s in "${SCREENS[@]}"; do
  echo "Capturing $s ..."
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BUNDLE" --screenshot "$s" >/dev/null
  sleep 6
  out="$RAW/$(printf '%02d' "$i")-$s.png"
  xcrun simctl io "$UDID" screenshot "$out"
  echo "  -> $out"
  i=$((i + 1))
done

echo "Raw screenshots written to $RAW"

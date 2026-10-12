#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_NAME="${IOS_SCREENSHOT_DEVICE:-iPhone 17e}"
IPAD_DEVICE_NAME="${IOS_IPAD_SCREENSHOT_DEVICE:-iPad Pro 13-inch (M5)}"
DERIVED_DATA_PATH="${IOS_DERIVED_DATA_PATH:-$SCRIPT_DIR/build/screenshots}"
SCREENSHOT_DIR="${IOS_SCREENSHOT_DIR:-$SCRIPT_DIR/screenshots}"
BUNDLE_ID="${IOS_BUNDLE_ID:-com.bvolpato.brutv}"
APP_PATH_OVERRIDE="${IOS_APP_PATH:-}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: screenshots require macOS with Xcode" >&2
  exit 1
fi

command -v xcodebuild >/dev/null 2>&1 || { echo "error: xcodebuild not found" >&2; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "error: xcrun not found" >&2; exit 1; }

mkdir -p "$SCREENSHOT_DIR"

if [[ -n "$APP_PATH_OVERRIDE" ]]; then
  APP_PATH="$APP_PATH_OVERRIDE"
else
  cd "$SCRIPT_DIR"
  xcodebuild clean build \
    -project BruTV.xcodeproj \
    -scheme BruTV \
    -destination "platform=iOS Simulator,name=$DEVICE_NAME" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGNING_ALLOWED=NO

  APP_PATH=$(find "$DERIVED_DATA_PATH" -name "BruTV.app" -type d | sort | head -n 1)
fi

[[ -d "$APP_PATH" ]] || {
  echo "error: app not found: $APP_PATH" >&2
  exit 1
}

capture_device() {
  local target_device="$1"
  local output_subdir="$2"
  local dev_id

  dev_id=$(xcrun simctl list devices available | grep "$target_device" | head -n 1 | sed 's/.*(\([A-Z0-9-]*\)).*/\1/')
  if [[ -z "$dev_id" ]]; then
    echo "warning: simulator not found: $target_device, skipping"
    return 0
  fi

  echo "Capturing on $target_device ($dev_id)..."
  xcrun simctl boot "$dev_id" >/dev/null 2>&1 || true
  sleep 4
  xcrun simctl install "$dev_id" "$APP_PATH"

  mkdir -p "$SCREENSHOT_DIR/$output_subdir"

  # 1. Login Screen
  xcrun simctl terminate "$dev_id" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$dev_id" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 3
  xcrun simctl io "$dev_id" screenshot "$SCREENSHOT_DIR/$output_subdir/01_login.png" >/dev/null || true

  # 2. Main Live Channels Screen (with Demo Login)
  xcrun simctl terminate "$dev_id" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$dev_id" "$BUNDLE_ID" --demo-login >/dev/null 2>&1 || true
  sleep 6
  xcrun simctl io "$dev_id" screenshot "$SCREENSHOT_DIR/$output_subdir/02_live_channels.png" >/dev/null || true

  # 3. Channel Guide & Player
  sleep 3
  xcrun simctl io "$dev_id" screenshot "$SCREENSHOT_DIR/$output_subdir/03_player_view.png" >/dev/null || true

  echo "  Done capturing on $target_device"
}

# Capture on iPhone
capture_device "$DEVICE_NAME" "iphone"

# Capture on iPad
capture_device "$IPAD_DEVICE_NAME" "ipad"

# Post-processing into required App Store Connect resolutions
echo "Post-processing screenshots into required App Store Connect resolutions..."

# 6.7-inch (1290 x 2796)
mkdir -p "$SCREENSHOT_DIR/6.7-inch"
for f in "$SCREENSHOT_DIR/iphone"/*.png; do
  [[ -f "$f" ]] || continue
  name=$(basename "$f")
  cp "$f" "$SCREENSHOT_DIR/6.7-inch/$name"
  sips -z 2796 1290 "$SCREENSHOT_DIR/6.7-inch/$name" >/dev/null
done
echo "  Generated 6.7-inch screenshots (1290 x 2796)"

# 6.5-inch (1242 x 2688)
mkdir -p "$SCREENSHOT_DIR/6.5-inch"
for f in "$SCREENSHOT_DIR/iphone"/*.png; do
  [[ -f "$f" ]] || continue
  name=$(basename "$f")
  cp "$f" "$SCREENSHOT_DIR/6.5-inch/$name"
  sips -z 2688 1242 "$SCREENSHOT_DIR/6.5-inch/$name" >/dev/null
done
echo "  Generated 6.5-inch screenshots (1242 x 2688)"

# iPad Pro 13-inch (2048 x 2732)
if [[ -d "$SCREENSHOT_DIR/ipad" ]]; then
  mkdir -p "$SCREENSHOT_DIR/ipad-13-inch"
  for f in "$SCREENSHOT_DIR/ipad"/*.png; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f")
    cp "$f" "$SCREENSHOT_DIR/ipad-13-inch/$name"
    sips -z 2732 2048 "$SCREENSHOT_DIR/ipad-13-inch/$name" >/dev/null
  done
  echo "  Generated iPad 13-inch screenshots (2048 x 2732)"
fi

echo "Screenshots generated in: $SCREENSHOT_DIR"

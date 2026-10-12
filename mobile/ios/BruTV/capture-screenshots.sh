#!/usr/bin/env bash
# Captures App Store screenshots with the testCaptureStoreScreenshots UI test.
# The test signs in with a public M3U playlist, so the images show no private account data.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IPHONE_DEVICE="${IOS_SCREENSHOT_DEVICE:-iPhone 18 Pro Max}"
IPAD_DEVICE="${IOS_IPAD_SCREENSHOT_DEVICE:-iPad Pro 13-inch (M5)}"
DERIVED_DATA_PATH="${IOS_DERIVED_DATA_PATH:-$SCRIPT_DIR/build/screenshots}"
SCREENSHOT_DIR="${IOS_SCREENSHOT_DIR:-$SCRIPT_DIR/screenshots}"
PLAYLIST="${BRUTV_SCREENSHOT_PLAYLIST:-https://iptv-org.github.io/iptv/countries/br.m3u}"
CATEGORY="${BRUTV_SCREENSHOT_CATEGORY:-Education}"
CHANNEL="${BRUTV_SCREENSHOT_CHANNEL:-Canal Futura}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: screenshots require macOS with Xcode" >&2
  exit 1
fi
command -v xcodebuild >/dev/null 2>&1 || { echo "error: xcodebuild not found" >&2; exit 1; }

cd "$SCRIPT_DIR"

capture_device() {
  local device="$1"
  local subdir="$2"
  local dev_id

  dev_id=$(xcrun simctl list devices available | grep -F "$device (" | head -n 1 | sed -E 's/.*\(([A-F0-9-]{36})\).*/\1/')
  if [[ -z "$dev_id" ]]; then
    echo "warning: simulator not found: $device, skipping"
    return 0
  fi

  echo "Capturing on $device ($dev_id)..."
  xcrun simctl boot "$dev_id" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$dev_id" -b >/dev/null
  xcrun simctl status_bar "$dev_id" override \
    --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true

  rm -rf "$SCREENSHOT_DIR/$subdir"
  mkdir -p "$SCREENSHOT_DIR/$subdir"

  local log="$SCREENSHOT_DIR/$subdir.xcodebuild.log"
  TEST_RUNNER_BRUTV_SCREENSHOT_DIR="$SCREENSHOT_DIR/$subdir" \
  TEST_RUNNER_BRUTV_SCREENSHOT_PLAYLIST="$PLAYLIST" \
  TEST_RUNNER_BRUTV_SCREENSHOT_CATEGORY="$CATEGORY" \
  TEST_RUNNER_BRUTV_SCREENSHOT_CHANNEL="$CHANNEL" \
  xcodebuild test \
    -project BruTV.xcodeproj \
    -scheme BruTV \
    -destination "platform=iOS Simulator,id=$dev_id" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -only-testing:BruTVUITests/BruTVUITests/testCaptureStoreScreenshots \
    CODE_SIGNING_ALLOWED=NO > "$log" 2>&1 &
  local pid=$!

  # xcodebuild can hang after the test ends. Stop it 20s after the suite result is logged.
  local done_at=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ $done_at -eq 0 ]] && grep -q "Test Suite 'Selected tests' \(passed\|failed\)" "$log"; then
      done_at=$SECONDS
    fi
    if [[ $done_at -gt 0 && $((SECONDS - done_at)) -ge 20 ]]; then
      kill "$pid" 2>/dev/null || true
      break
    fi
    sleep 2
  done
  wait "$pid" 2>/dev/null || true

  if ! grep -q "Test Suite 'Selected tests' passed" "$log"; then
    tail -40 "$log" >&2
    echo "error: screenshot test failed on $device. Full log: $log" >&2
    exit 1
  fi
  rm -f "$log"

  xcrun simctl status_bar "$dev_id" clear || true
  echo "  Saved to $SCREENSHOT_DIR/$subdir"
  for f in "$SCREENSHOT_DIR/$subdir"/*.png; do
    [[ -f "$f" ]] && echo "  $(basename "$f"): $(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/ {printf "%s ", $2}')"
  done
}

capture_device "$IPHONE_DEVICE" "iphone-6.9-inch"
capture_device "$IPAD_DEVICE" "ipad-13-inch"

echo "Screenshots generated in: $SCREENSHOT_DIR"

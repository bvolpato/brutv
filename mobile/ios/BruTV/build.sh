#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TARGET="${1:-ios}"
if [[ "$TARGET" == "--tvos" || "$TARGET" == "tvos" ]]; then
  DESTINATION="${TVOS_SIM_DESTINATION:-generic/platform=tvOS Simulator}"
  DERIVED_DATA_PATH="${TVOS_DERIVED_DATA_PATH:-$SCRIPT_DIR/build/simulator-tvos}"
  SCHEME="BruTV-tvOS"
  APP_NAME="BruTV-tvOS.app"
else
  DESTINATION="${IOS_SIM_DESTINATION:-platform=iOS Simulator,name=iPhone 17e}"
  DERIVED_DATA_PATH="${IOS_DERIVED_DATA_PATH:-$SCRIPT_DIR/build/simulator}"
  SCHEME="BruTV"
  APP_NAME="BruTV.app"
fi
CONFIGURATION="${IOS_CONFIGURATION:-Debug}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: Apple platform builds require macOS with Xcode" >&2
  exit 1
fi

command -v xcodebuild >/dev/null 2>&1 || {
  echo "error: xcodebuild not found" >&2
  exit 1
}

cd "$SCRIPT_DIR"
xcodebuild build \
  -project BruTV.xcodeproj \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO

APP_PATH=$(find "$DERIVED_DATA_PATH" -name "$APP_NAME" -type d | sort | head -n 1 || true)
if [[ -n "$APP_PATH" ]]; then
  echo "app: $APP_PATH"
fi

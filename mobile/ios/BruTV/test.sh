#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "--core" ]]; then
  shift
  exec "$SCRIPT_DIR/test-core.sh" "$@"
fi
source "$SCRIPT_DIR/apple-sdk.sh"
DESTINATION="${IOS_SIM_DESTINATION:-platform=iOS Simulator,name=iPhone 17e}"
DERIVED_DATA_PATH="${IOS_DERIVED_DATA_PATH:-$SCRIPT_DIR/build/test}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: iOS tests require macOS with Xcode" >&2
  exit 1
fi

command -v xcodebuild >/dev/null 2>&1 || {
  echo "error: xcodebuild not found" >&2
  exit 1
}
brutv_require_xcode_sdk iphonesimulator

cd "$SCRIPT_DIR"
xcodebuild test \
  -project BruTV.xcodeproj \
  -scheme BruTV \
  -sdk iphonesimulator \
  -destination "$DESTINATION" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO

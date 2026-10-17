#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo "Usage: setup-linux.sh /path/to/Xcode.xip | --signing-tools | --catalyst-linker"
  echo "Extracts and installs the Apple SDK using xtool. Accept Apple's license when downloading Xcode."
  echo "Set XTOOL_SOURCE_DIR to the tested fork, or SWIFT_BINARY and XTOOL_BINARY to installed tools."
  exit 0
fi
if [[ "${1:-}" == --catalyst-linker ]]; then
  exec "$SCRIPT_DIR/setup-linux-linker.sh"
fi
if [[ "${1:-}" == --signing-tools ]]; then
  "$SCRIPT_DIR/setup-zsign.sh"
  exec "$SCRIPT_DIR/setup-mac-tools.sh"
fi
export XCODE_XIP_PATH="${1:-${XCODE_XIP_PATH:-}}"
[[ -n "$XCODE_XIP_PATH" && -e "$XCODE_XIP_PATH" ]] || {
  echo "error: provide the downloaded Xcode.xip path, or set XCODE_XIP_PATH" >&2
  exit 1
}
XCODE_XIP_PATH="$(realpath "$XCODE_XIP_PATH")"
export XCODE_XIP_PATH
"${SWIFT_BINARY:-$SCRIPT_DIR/swift-linux.sh}" --version
"${XTOOL_BINARY:-$SCRIPT_DIR/xtool-linux.sh}" sdk install --slim "$XCODE_XIP_PATH" 2>&1 | \
  awk 'BEGIN { RS="[\r\n]" } NF && $0 != previous { print; fflush(); previous=$0 }'
SDK_STATUS="$("${XTOOL_BINARY:-$SCRIPT_DIR/xtool-linux.sh}" sdk status)"
printf '%s\n' "$SDK_STATUS"
[[ "$SDK_STATUS" == *"Darwin SDK is installed"* ]] || {
  echo "error: SDK installation did not persist in the build toolchain" >&2
  exit 1
}

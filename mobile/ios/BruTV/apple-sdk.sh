#!/usr/bin/env bash
# Shared SDK floor. Deployment targets remain configured in the Xcode project.

brutv_require_sdk_version() {
  local sdk="$1" version="$2" major minor
  if [[ ! "$version" =~ ^([0-9]{1,3})\.([0-9]{1,3})(\.[0-9]{1,3})?$ ]]; then
    echo "error: cannot determine $sdk SDK version from '$version'; SDK 27.2 or later is required" >&2
    return 1
  fi
  major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"
  if (( 10#$major < 27 || (10#$major == 27 && 10#$minor < 2) )); then
    echo "error: $sdk SDK 27.2 or later is required; selected SDK is $version. Select Xcode 27.2 or install its unmodified Darwin SDK." >&2
    return 1
  fi
}

brutv_require_xcode_sdk() {
  local sdk="$1" version
  if ! version="$(xcrun --sdk "$sdk" --show-sdk-version)"; then
    echo "error: cannot read the selected $sdk SDK; Xcode 27.2 with SDK 27.2 or later is required" >&2
    return 1
  fi
  brutv_require_sdk_version "$sdk" "$version"
}

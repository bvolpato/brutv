#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
exec ./gradlew :app:assembleDebug :app:assemblePreview :app:assembleRelease :app:bundleRelease "$@"

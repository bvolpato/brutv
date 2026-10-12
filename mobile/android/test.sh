#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
exec ./gradlew :app:testDebugUnitTest :app:lintDebug :app:lintPreview :app:lintRelease "$@"

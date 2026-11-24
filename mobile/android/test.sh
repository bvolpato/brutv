#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

full_lint=false
gradle_args=()
for arg in "$@"; do
    if [[ "$arg" == "--full-lint" ]]; then
        full_lint=true
    else
        gradle_args+=("$arg")
    fi
done

if [[ "$full_lint" = true || -n "${CI:-}" ]]; then
    exec ./gradlew :app:testDebugUnitTest :app:lintDebug :app:lintRelease "${gradle_args[@]}"
else
    exec ./gradlew :app:testDebugUnitTest :app:lintDebug "${gradle_args[@]}"
fi

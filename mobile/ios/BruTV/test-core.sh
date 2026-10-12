#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if command -v swift >/dev/null 2>&1; then
  exec swift test --scratch-path build/core-tests --jobs 4 "$@"
fi

command -v docker >/dev/null 2>&1 || {
  echo "error: core tests require Swift or Docker" >&2
  exit 1
}

exec docker run --rm --network none --cpus 4 --memory 4g \
  --user "$(id -u):$(id -g)" \
  --volume "$PWD:/workspace" --workdir /workspace \
  swift:6.4.0-noble@sha256:31d14d727f4451f25e29bac9c42563a098c39ac66415e8bad970f48038e38aca \
  swift test --scratch-path build/core-tests --jobs 4 \
  --cache-path build/core-tests/cache \
  --config-path build/core-tests/config \
  --security-path build/core-tests/security "$@"

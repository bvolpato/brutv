#!/usr/bin/env bash
set -euo pipefail
ps5_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cmake -S "$ps5_root" -B "$ps5_root/build/desktop" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo "$@"
cmake --build "$ps5_root/build/desktop" --parallel "${BRUTV_JOBS:-4}"

#!/usr/bin/env bash
set -euo pipefail

task_root=$(cd "$(dirname "$0")/.." && pwd)
task_build=$(mktemp -d "${TMPDIR:-/tmp}/brutv-shaka.XXXXXXXX")
trap 'rm -rf "$task_build"' EXIT

expected_archive=8a9d55c8bb9fdf08b40f46a308e47d6530cc31a251e381086434d77da17ff90f
actual_archive=$(shasum -a 256 "$task_root/vendor/amazon/shaka-rel-v4.8.5-r1.7.tar.gz" | cut -d ' ' -f 1)
if [ "$actual_archive" != "$expected_archive" ]; then
  printf '%s\n' 'The vendored Amazon Shaka archive checksum differs from the reviewed source.' >&2
  exit 1
fi
git clone --depth 1 --branch v4.8.5 https://github.com/shaka-project/shaka-player.git "$task_build/shaka-player"
tar -xzf "$task_root/vendor/amazon/shaka-rel-v4.8.5-r1.7.tar.gz" -C "$task_build"
cd "$task_build/shaka-player"
if [ "$(git rev-parse HEAD)" != 9ef114308b71e304327540f138de36f46f4a8f39 ]; then
  printf '%s\n' 'The upstream Shaka tag no longer matches the reviewed commit.' >&2
  exit 1
fi
for patch in "$task_build"/shaka-rel/shaka-patch/*.patch; do git apply "$patch"; done
python3 build/all.py
mkdir -p "$task_root/src/media/shaka"
cp dist/shaka-player.compiled.js "$task_root/src/media/shaka/"
cp dist/shaka-player.compiled.d.ts "$task_root/src/media/shaka/"
cp LICENSE "$task_root/src/media/shaka/LICENSE"
printf '%s\n' 'Built Amazon-patched Shaka 4.8.5-r1.7. Native Vega packaging is a separate step.'

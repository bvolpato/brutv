#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
[[ $# == 0 ]] || { echo 'usage: bootstrap.sh' >&2; exit 2; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cache=${BRUTV_PS5_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/brutv-ps5}
[[ $cache == /* && $cache != / && $cache != *$'\n'* && $cache != *' '* ]] || {
    echo 'BRUTV_PS5_CACHE must be an absolute path without whitespace' >&2; exit 2;
}
for tool in curl sha256sum tar unzip git jq cmake ninja clang-18 clang++-18 ld.lld-18 llvm-ar-18 llvm-ranlib-18 llvm-readelf-18 make pkg-config zip rg; do
    command -v "$tool" >/dev/null || { echo "missing build tool: $tool" >&2; exit 2; }
done
mkdir -p "$cache/downloads"
fetch() {
    local name=$1 hash=$2 url=$3 file="$cache/downloads/$1"
    if ! [[ -f $file ]] || ! printf '%s  %s\n' "$hash" "$file" | sha256sum -c --status; then
        curl --fail --location --retry 3 --connect-timeout 20 --output "$file.part" "$url" >&2
        printf '%s  %s\n' "$hash" "$file.part" | sha256sum -c --status || {
            echo "SHA-256 mismatch: $name" >&2; exit 2;
        }
        mv -- "$file.part" "$file"
    fi
}
fetch sdk-0.43.zip a9cc9929f21b2b2c5d5b309f3bab4997067c45281c0622cf4838b1aecba66fcb \
    https://github.com/ps5-payload-dev/sdk/releases/download/v0.43/ps5-payload-sdk.zip
fetch ps5-opengl-1.0.0.tar.gz f93643c04c843d56143b00951df1f8042ea7706ae9f19e4e9abf158e1ead77c5 \
    https://github.com/blackbearreloaded/ps5-opengl/releases/download/v1.0.0/ps5-opengl-sdk-1.0.0.tar.gz
fetch pacbrew-0.40.3.tar.gz 0d71dd90c4ad6ef562923be0eb87ca8ce47825b6a2f209e04bb5d57d3359aee8 \
    https://github.com/ps5-payload-dev/pacbrew-repo/releases/download/v0.40.3/ps5-payload-dev.tar.gz
fetch json-3.11.3-LICENSE.MIT 86b998c792894ccb911a1cb7994f7a9652894e7a094c0b5e45be2f553f45cf14 \
    https://raw.githubusercontent.com/nlohmann/json/v3.11.3/LICENSE.MIT
sdk="$cache/sdk-0.43/ps5-payload-sdk"
if [[ ! -x $sdk/bin/prospero-lld ]]; then
    mkdir -p "$cache/sdk-0.43"
    unzip -q -o "$cache/downloads/sdk-0.43.zip" -d "$cache/sdk-0.43"
fi
opengl="$cache/ps5-opengl-1.0.0"
if [[ ! -f $opengl/sdk/manifest.sha256 ]]; then
    mkdir -p "$opengl"
    tar -xzf "$cache/downloads/ps5-opengl-1.0.0.tar.gz" -C "$opengl" --strip-components=1
fi
printf '%s  %s\n' f4b91f672be037fbac3f82494f1225deaf4c227a03f37ac3ffa56abb213b943f "$opengl/sdk/manifest.sha256" | sha256sum -c --status
(cd "$opengl" && sha256sum --check --strict SHA256SUMS >/dev/null)
(cd "$opengl/sdk" && sha256sum --check --strict manifest.sha256 >/dev/null)
mkdir -p "$opengl/source"
tar -xf "$opengl/sources/ps5-opengl.tar" -C "$opengl/source" --strip-components=1 \
    ps5-opengl/native-app/cts_runtime_shims.c
pacbrew="$cache/pacbrew-0.40.3"
if [[ ! -f $pacbrew/user/homebrew/lib/pkgconfig/libavformat.pc ]]; then
    mkdir -p "$pacbrew"
    tar -xzf "$cache/downloads/pacbrew-0.40.3.tar.gz" -C "$pacbrew" --strip-components=3 \
        opt/ps5-payload-sdk/target/user/homebrew
fi
native="$cache/native-app-44ae1dab"
commit=44ae1dab529654eac795d2a7c4f5a0425102b8d7
if [[ ! -d $native/.git ]]; then
    git init -q "$native"
    git -C "$native" remote add origin https://github.com/blackbearreloaded/ps5-native-app-boilerplate.git
    git -C "$native" fetch -q --depth 1 origin "$commit"
    git -C "$native" checkout -q --detach FETCH_HEAD
fi
[[ $(git -C "$native" rev-parse HEAD) == "$commit" ]] || {
    echo 'Native tooling cache revision does not match its pin' >&2; exit 2;
}
# Carry the same finite application heap budget as upstream's native OpenGL
# builder. Validate the complete tracked diff before executing cached tooling.
patch="$root/tools/native-tooling.patch"
if git -C "$native" diff --quiet; then
    git -C "$native" apply --check "$patch"
    git -C "$native" apply "$patch"
else
    git -C "$native" apply --reverse --check "$patch"
    [[ $(git -C "$native" diff --name-only) == tooling/native/sce_module_writer.cpp ]] || {
        echo 'Unexpected edits in the native tooling cache' >&2; exit 2;
    }
fi
cmp <(git -C "$native" show HEAD:tooling/native/sce_module_writer.cpp |
    sed 's/write_u64(result.data, result.heap_size, std::numeric_limits<std::uint64_t>::max());/write_u64(result.data, result.heap_size, 0x10000000ULL);/') \
    "$native/tooling/native/sce_module_writer.cpp"
# The upstream helpers are GPL source-built host utilities. Only their zlib and
# runtime paths are used; their older SDK/PacBrew bootstrap is not invoked.
USE_CCACHE=0 bash "$native/tools/setup-native-dependencies.sh" --skip-sdk >/dev/null
USE_CCACHE=0 bash "$native/tools/build-host-tools.sh" >&2
if [[ ! -f $native/runtime/libc.prx ]] || ! (cd "$native/runtime" && sha256sum -c --status libc.prx.sha256); then
    USE_CCACHE=0 bash "$native/tools/rebuild-libc.sh" >&2
fi
jq -n --arg cache "$cache" --arg sdk "$sdk" --arg opengl "$opengl" --arg pacbrew "$pacbrew" --arg native "$native" \
    '{cache:$cache,sdk:$sdk,opengl:$opengl,pacbrew:$pacbrew,native:$native}'

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
[[ $# == 0 ]] || { echo 'usage: build-ps5.sh' >&2; exit 2; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
deps=$(bash "$root/tools/bootstrap.sh")
export PS5_PAYLOAD_SDK BRUTV_PS5_OPENGL BRUTV_PS5_NATIVE BRUTV_PS5_PACBREW
PS5_PAYLOAD_SDK=$(jq -er .sdk <<< "$deps")
BRUTV_PS5_OPENGL=$(jq -er .opengl <<< "$deps")
BRUTV_PS5_NATIVE=$(jq -er .native <<< "$deps")
BRUTV_PS5_PACBREW=$(jq -er .pacbrew <<< "$deps")
export PKG_CONFIG_DIR=
export PKG_CONFIG_SYSROOT_DIR="$BRUTV_PS5_PACBREW"
export PKG_CONFIG_LIBDIR="$BRUTV_PS5_PACBREW/user/homebrew/lib/pkgconfig:$BRUTV_PS5_PACBREW/user/homebrew/libdata/pkgconfig"
export PKG_CONFIG_PATH=
build="$root/build/ps5"
mkdir -p "$build/deps/include"
# Header-only JSON is pinned separately, never add host /usr/include to a target
# include path. The single header is MIT-licensed and SHA-256 checked.
json="$build/deps/include/nlohmann/json.hpp"
json_hash=9bea4c8066ef4a1c206b2be5a36302f8926f7fdc6087af5d20b417d0cf103ea6
mkdir -p "$(dirname "$json")"
if [[ ! -f $json ]] || ! printf '%s  %s\n' "$json_hash" "$json" | sha256sum -c --status; then
    curl --fail --location --retry 3 --output "$json.part" \
        https://raw.githubusercontent.com/nlohmann/json/v3.11.3/single_include/nlohmann/json.hpp
    printf '%s  %s\n' "$json_hash" "$json.part" | sha256sum -c --status || {
        echo 'nlohmann/json header SHA-256 mismatch' >&2; exit 2;
    }
    mv "$json.part" "$json"
fi
cmake -S "$root" -B "$build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$root/cmake/PS5.cmake" -DCMAKE_BUILD_TYPE=Release \
    -DPKG_CONFIG_EXECUTABLE=/usr/bin/pkg-config -DBRUTV_PS5=ON -DBUILD_TESTING=OFF -DBRUTV_JSON_INCLUDE_DIR="$build/deps/include"
cmake --build "$build" --parallel "${BUILD_JOBS:-4}"
bash "$root/tools/package-ps5.sh"

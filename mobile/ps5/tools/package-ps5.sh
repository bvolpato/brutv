#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
[[ $# == 0 ]] || { echo 'usage: package-ps5.sh' >&2; exit 2; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cache=${BRUTV_PS5_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/brutv-ps5}
sdk="$cache/sdk-0.43/ps5-payload-sdk"
native="$cache/native-app-44ae1dab"
opengl="$cache/ps5-opengl-1.0.0"
build="$root/build/ps5"
tool="$native/build/host/ps5-native-tool"
input="$build/brutv"
[[ -s $input && -x $tool ]] || { echo 'Build the native PS5 target first' >&2; exit 2; }
if llvm-readelf-18 --dynamic "$input" | rg -q 'libScePosixForWebKit|libSceRandom|RPATH|RUNPATH'; then
    echo 'Native import audit failed: unavailable WebKit POSIX/Random module or build-host runpath' >&2
    exit 2
fi
param="$root/sce_sys/param.json"
title=$(jq -er '.titleId | select(test("^PPSA[0-9]{5}$"))' "$param")
jq -e --arg title "$title" '
  .applicationCategoryType == 65536 and .contentBadgeType == 2 and
  (.contentId | test("^[A-Z]{2}[0-9]{4}-PPSA[0-9]{5}_00-[A-Z0-9]{16}$")) and
  (.contentId | contains($title)) and
  (.contentVersion | test("^[0-9]{2}\\.[0-9]{3}\\.[0-9]{3}$")) and
  (.localizedParameters[.localizedParameters.defaultLanguage].titleName == "BruTV")
' "$param" >/dev/null
"$tool" link --in "$input" --out "$build/eboot.elf" \
    --stub-dir "$sdk/target/lib" --stub "$opengl/sdk/lib/libSceAgc.so" --stub "$opengl/sdk/lib/libSceAgcDriver.so" \
    --module-sdk 0x02000009 --companion-sdk 0x08050001 --file-name eboot.elf
stage=$(mktemp -d "$build/title-staging.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
app="$stage/$title"
mkdir -p "$app/sce_sys" "$app/sce_module" "$app/licenses"
"$tool" self --sign --in "$build/eboot.elf" --out "$app/eboot.bin" --magic 0x1D3D154F
cp "$param" "$app/sce_sys/param.json"
cp -a "$root/assets" "$app/assets"
cp "$cache/pacbrew-0.40.3/user/homebrew/etc/ca-bundle.crt" "$app/assets/ca-bundle.crt"
[[ ! -f $root/assets/icon0.png ]] || cp "$root/assets/icon0.png" "$app/sce_sys/icon0.png"
(cd "$native/runtime" && sha256sum -c --strict libc.prx.sha256)
cp "$native/runtime/libc.prx" "$app/sce_module/libc.prx"
cp "$root/LICENSE" "$app/licenses/BruTV-PS5-GPL-3.0.txt"
cp "$root/THIRD_PARTY_NOTICES.md" "$app/licenses/THIRD_PARTY_NOTICES.md"
cp "$cache/downloads/json-3.11.3-LICENSE.MIT" "$app/licenses/nlohmann-json-MIT.txt"
cp -a "$opengl/LICENSES" "$app/licenses/PS5OpenGL"
cp "$opengl/THIRD_PARTY_NOTICES.md" "$app/licenses/PS5OpenGL-NOTICES.md"
jq -n --arg title "$title" \
    --arg native 44ae1dab529654eac795d2a7c4f5a0425102b8d7 \
    --arg sdk a9cc9929f21b2b2c5d5b309f3bab4997067c45281c0622cf4838b1aecba66fcb \
    --arg opengl f93643c04c843d56143b00951df1f8042ea7706ae9f19e4e9abf158e1ead77c5 \
    --arg ports 0d71dd90c4ad6ef562923be0eb87ca8ce47825b6a2f209e04bb5d57d3359aee8 \
    --arg patch "$(sha256sum "$root/tools/native-tooling.patch" | cut -d ' ' -f 1)" \
    '{title:$title,native_tooling_commit:$native,native_tooling_patch_sha256:$patch,payload_sdk:"0.43",sdk_archive_sha256:$sdk,opengl:"1.0.0",opengl_archive_sha256:$opengl,pacbrew:"0.40.3",pacbrew_archive_sha256:$ports,console_tested:false,format:"ShadowMount directory title"}' > "$app/build-provenance.json"
"$tool" self --inspect --file "$app/eboot.bin"
"$tool" self --inspect --file "$app/sce_module/libc.prx"
# The reference directory loader requires 0777 ZIP entries. Only the temporary
# staging tree uses these modes; normal host artifact permissions follow below.
chmod -R 777 "$app"
(cd "$stage" && zip -q -X -r "$stage/$title.zip" "$title")
find "$app" -type d -exec chmod 755 {} +
find "$app" -type f -exec chmod 644 {} +
mkdir -p "$build/title"
[[ ! -e $build/title/$title ]] || mv "$build/title/$title" "$stage/previous-$title"
mv "$app" "$build/title/$title"
mv "$stage/$title.zip" "$build/$title.zip"
(cd "$build" && sha256sum "$title.zip" "title/$title/eboot.bin" > SHA256SUMS)
printf 'Native title: %s\nArchive: %s\n' "$build/title/$title" "$build/$title.zip"

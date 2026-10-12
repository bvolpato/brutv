#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ -n "${KEPLER_SDK_PATH:-}" ]]; then
    export PATH="$KEPLER_SDK_PATH/bin:$PATH"
fi
if ! command -v vega >/dev/null; then
    echo "Activate Vega SDK 0.23 before building a release package." >&2
    exit 1
fi
sdk_version="$(vega --version)"
if [[ "$sdk_version" != 0.23.* ]]; then
    echo "BruTV requires the Vega SDK 0.23 track; active SDK: $sdk_version." >&2
    exit 1
fi

target="${BRUTV_VEGA_TARGET:-armv7}"
case "$target" in
    armv7|aarch64|x86_64) ;;
    *) echo "Unsupported Vega target: $target." >&2; exit 1 ;;
esac
version="$(node -p 'require("./package.json").version')"
build_number="${BRUTV_VEGA_BUILD_NUMBER:-2}"
if [[ ! "$build_number" =~ ^[0-9]+$ ]]; then
    echo "BRUTV_VEGA_BUILD_NUMBER must be a nonnegative integer." >&2
    exit 1
fi

npm ci --ignore-scripts
npm test
npm run setup:shaka
npm run typecheck
vega exec vpt validate "$PWD/manifest.toml"
npm run build:release -- --target "$target" --build-version "$version" --build-number "$build_number"

package="build/private/kepler/brutv-vega/0.1/vega/$target/Release/brutv-vega_$target.vpkg"
if [[ ! -f "$package" ]]; then
    echo "The native build did not produce the expected Vega package: $package." >&2
    exit 1
fi
vega exec vpt validate "$package"
package_info="$(vega exec vpt info "$package" --json)"
printf '%s\n' "$package_info" | node -e '
const fs = require("fs");
const info = JSON.parse(fs.readFileSync(0, "utf8"));
if (info.id !== "com.bvolpato.brutv" || info.version !== process.argv[1] || BigInt(info.build_number) !== BigInt(process.argv[2])) {
  throw new Error("Vega package identity or version does not match this release.");
}
' "$version" "$build_number"

distribution_dir="build/distributions"
mkdir -p "$distribution_dir"
final_package="$distribution_dir/BruTV-vega-$target-$version-$build_number.vpkg"
cp "$package" "$final_package"
printf 'Vega package: %s\n' "$final_package"
printf '%s\n' "$package_info"
sha256sum "$final_package"
printf 'Appstore approval and device validation are separate from local package generation.\n'

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM=ios
CONFIGURATION="${IOS_CONFIGURATION:-debug}"
OUTPUT="${IOS_LINUX_BUILD_DIR:-}"
PREPARE_ONLY=false
CHECK_ONLY=false
XTOOL_BINARY="${XTOOL_BINARY:-$SCRIPT_DIR/xtool-linux.sh}"
SWIFT_BINARY="${SWIFT_BINARY:-$SCRIPT_DIR/swift-linux.sh}"
DSYMUTIL="${DSYMUTIL:-}"
if [[ -z "${RCODESIGN:-}" ]]; then
  MAC_TOOLS_DIR="${BRUTV_MAC_TOOLS_DIR:-$SCRIPT_DIR/build/tools}"
  if [[ -x "$MAC_TOOLS_DIR/bin/rcodesign" ]]; then
    RCODESIGN="$MAC_TOOLS_DIR/bin/rcodesign"
  else
    RCODESIGN=rcodesign
  fi
fi

usage() {
  cat <<'USAGE'
Usage: linux-build.sh [--platform ios|tvos|macos] [--configuration debug|release]
                      [--output DIRECTORY] [--prepare-only|--check]

Build BruTV's native iPhone/iPad or universal Mac Catalyst app with xtool on Linux. Requires Swift 6.4,
xtool, and its Apple Darwin SDK. The output is DIRECTORY/xtool/BruTV.app.
--prepare-only compiles resources and prepares the package without an Apple SDK.
--check verifies the toolchain and SDK without preparing or building an app.
Mac Catalyst requires the BruTV xtool fork and rcodesign for universal packaging.
Release builds also emit DIRECTORY/xtool/BruTV.app.dSYM using the SDK's dsymutil.
tvOS requires a brandassets compiler and currently fails explicitly.
XTOOL_BINARY and SWIFT_BINARY may select executable paths.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform|--configuration|--output)
      [[ $# -gt 1 && -n "$2" ]] || { echo "error: $1 requires a value" >&2; exit 2; }
      case "$1" in
        --platform) PLATFORM="$2" ;;
        --configuration) CONFIGURATION="$2" ;;
        --output) OUTPUT="$2" ;;
      esac
      shift 2
      ;;
    --prepare-only) PREPARE_ONLY=true; shift ;;
    --check) CHECK_ONLY=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$PLATFORM" in
  ios) ;;
  tvos)
    echo "error: BruTV's TVAppIcon.brandassets uses imagestack layers that the Linux AssetKit compiler cannot compile. A verified tvOS asset catalog compiler is required before building the tvOS app and TopShelf extension." >&2
    exit 1
    ;;
  macos) ;;
  *) echo "error: unsupported Apple platform: $PLATFORM" >&2; exit 2 ;;
esac
OUTPUT="${OUTPUT:-$SCRIPT_DIR/build/linux-$PLATFORM}"
if [[ "$PREPARE_ONLY" = true && "$CHECK_ONLY" = true ]]; then
  echo "error: --prepare-only and --check are mutually exclusive" >&2
  exit 2
fi
case "$CONFIGURATION" in
  Debug|debug) CONFIGURATION=debug ;;
  Release|release) CONFIGURATION=release ;;
  *) echo "error: unsupported configuration: $CONFIGURATION" >&2; exit 2 ;;
esac

command -v "$SWIFT_BINARY" >/dev/null 2>&1 || {
  echo "error: Swift 6.4 is required on Linux. Install the toolchain described by xtool's Linux installation guide, or set SWIFT_BINARY." >&2
  exit 1
}
SWIFT_VERSION="$("$SWIFT_BINARY" --version)"
if [[ "$SWIFT_VERSION" =~ Swift\ version\ ([0-9]+)\.([0-9]+) ]]; then
  if (( BASH_REMATCH[1] < 6 || (BASH_REMATCH[1] == 6 && BASH_REMATCH[2] < 4) )); then
    echo "error: xtool builds require Swift 6.4 or later. Found: $SWIFT_VERSION" >&2
    exit 1
  fi
else
  echo "error: cannot determine the Swift version: $SWIFT_VERSION" >&2
  exit 1
fi

if [[ "$PREPARE_ONLY" = false ]]; then
  command -v "$XTOOL_BINARY" >/dev/null 2>&1 || {
    echo "error: the BruTV xtool fork is required on Linux. Set XTOOL_SOURCE_DIR to its checkout, or XTOOL_BINARY to the built fork." >&2
    exit 1
  }
  if ! SUPPORTED_PLATFORMS="$("$XTOOL_BINARY" dev build --print-supported-platforms 2>/dev/null)"; then
    echo "error: Linux BruTV builds require the BruTV xtool fork with SDK validation and release metadata fixes. Upstream xtool is insufficient. Set XTOOL_SOURCE_DIR to the tested fork checkout, or XTOOL_BINARY to its executable." >&2
    exit 1
  fi
  SDK_STATUS="$("$XTOOL_BINARY" sdk status)"
  if [[ "$SDK_STATUS" != *"Darwin SDK is installed"* ]]; then
    echo "error: Apple Darwin SDK is missing. Download Xcode.xip from Apple, then run: xtool sdk install /path/to/Xcode.xip" >&2
    exit 1
  fi
  LINKER_BINARY="${XTOOL_LD64_LLD:-}"
  LLVM_TOOLS_DIR="${BRUTV_LLVM_TOOLS_DIR:-$SCRIPT_DIR/build/tools/llvm}"
  if [[ -z "$LINKER_BINARY" && -x "$LLVM_TOOLS_DIR/bin/ld64.lld" ]]; then
    LINKER_BINARY="$(realpath -s "$LLVM_TOOLS_DIR/bin/ld64.lld")"
    export XTOOL_LD64_LLD="$LINKER_BINARY"
  fi
  if [[ -n "$LINKER_BINARY" && ( "$LINKER_BINARY" != /* || ! -x "$LINKER_BINARY" ) ]]; then
    echo "error: XTOOL_LD64_LLD must name a linker executable at an absolute path: $LINKER_BINARY" >&2
    exit 1
  fi
  if [[ "$PLATFORM" = macos ]]; then
    if [[ -z "$LINKER_BINARY" ]]; then
      while IFS= read -r line; do
        if [[ "$line" == "  Path: "* ]]; then
          LINKER_BINARY="${line#"  Path: "}/toolset/bin/ld64.lld"
          break
        fi
      done <<< "$SDK_STATUS"
    fi
    if [[ ! -x "$LINKER_BINARY" ]]; then
      echo "error: the Catalyst linker is missing. Run setup-linux.sh --catalyst-linker or set XTOOL_LD64_LLD." >&2
      exit 1
    fi
    LINKER_VERSION="$("$LINKER_BINARY" --version)" || {
      echo "error: cannot run the Catalyst linker: $LINKER_BINARY" >&2
      exit 1
    }
    LINKER_MAJOR=0
    if [[ "$LINKER_VERSION" =~ ^LLD[[:space:]]+([0-9]+) ]]; then
      LINKER_MAJOR="${BASH_REMATCH[1]}"
    fi
    if (( LINKER_MAJOR < 23 )); then
      echo "error: Mac Catalyst requires LLD 23 or newer for arm64e SDK reexports. Run setup-linux.sh --catalyst-linker. Found: $LINKER_VERSION" >&2
      exit 1
    fi
  fi
  if [[ "$CONFIGURATION" = release ]]; then
    if [[ -z "$DSYMUTIL" ]]; then
      while IFS= read -r line; do
        if [[ "$line" == "  Path: "* && -x "${line#"  Path: "}/toolset/bin/dsymutil" ]]; then
          DSYMUTIL="${line#"  Path: "}/toolset/bin/dsymutil"
          break
        fi
      done <<< "$SDK_STATUS"
      DSYMUTIL="${DSYMUTIL:-dsymutil}"
    fi
    command -v "$DSYMUTIL" >/dev/null 2>&1 || {
      echo "error: release crash symbols require dsymutil from the xtool SDK. Set DSYMUTIL to its executable path." >&2
      exit 1
    }
  fi
  if [[ "$PLATFORM" = macos ]]; then
    if [[ "$SUPPORTED_PLATFORMS" != *"macCatalyst"* ]]; then
      echo "error: the selected xtool does not support Mac Catalyst. Use the BruTV xtool fork through XTOOL_SOURCE_DIR or XTOOL_BINARY." >&2
      exit 1
    fi
    "$XTOOL_BINARY" sdk status --triple arm64-apple-ios-macabi >/dev/null || {
      echo "error: the selected xtool SDK lacks current Catalyst arm64 support. Use the tested BruTV fork and rerun setup-linux.sh." >&2
      exit 1
    }
    "$XTOOL_BINARY" sdk status --triple x86_64-apple-ios-macabi >/dev/null || {
      echo "error: the selected xtool SDK lacks current Catalyst x86_64 support. Use the tested BruTV fork and rerun setup-linux.sh." >&2
      exit 1
    }
    command -v "$RCODESIGN" >/dev/null 2>&1 || { echo "error: rcodesign is required to combine the Catalyst arm64 and x86_64 executables. Set RCODESIGN to its path." >&2; exit 1; }
  else
    "$XTOOL_BINARY" sdk status --triple arm64-apple-ios >/dev/null || {
      echo "error: the selected xtool SDK lacks current iOS validation support. Use the tested BruTV fork and rerun setup-linux.sh." >&2
      exit 1
    }
  fi
fi

if [[ "$CHECK_ONLY" = true ]]; then
  echo "toolchain: ready for $PLATFORM"
  exit 0
fi

mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
prepare() {
  "$SWIFT_BINARY" run --package-path "$SCRIPT_DIR/linux-tools" \
    --scratch-path "$SCRIPT_DIR/build/asset-compiler" --configuration release --jobs "${IOS_BUILD_JOBS:-4}" \
    prepare-xtool "$SCRIPT_DIR" "$1" "$PLATFORM"
}

if [[ "$PREPARE_ONLY" = true ]]; then
  prepare "$OUTPUT"
  exit 0
fi

build() {
  local destination="$1" triple="$2"
  prepare "$destination"
  (
    cd "$destination"
    BRUTV_XTOOL=1 BRUTV_XTOOL_PLATFORM="$PLATFORM" "$XTOOL_BINARY" dev build --configuration "$CONFIGURATION" --triple "$triple"
  )
}

if [[ "$PLATFORM" = macos ]]; then
  build "$OUTPUT/arm64" arm64-apple-ios-macabi
  build "$OUTPUT/x86_64" x86_64-apple-ios-macabi
  ARM_APP="$OUTPUT/arm64/xtool/BruTV.app"
  X86_APP="$OUTPUT/x86_64/xtool/BruTV.app"
  if compgen -G "$ARM_APP/Contents/Frameworks/*" >/dev/null || compgen -G "$X86_APP/Contents/Frameworks/*" >/dev/null; then
    echo "error: Catalyst dependencies now embed frameworks. Merge each framework's architecture slices before packaging the universal app." >&2
    exit 1
  fi
  mkdir -p "$OUTPUT/xtool"
  TEMP_APP="$(mktemp -d "$OUTPUT/xtool/.BruTV.XXXXXX")"
  cp -a "$ARM_APP/." "$TEMP_APP/"
  "$RCODESIGN" -C /dev/null macho-universal-create \
    --output "$TEMP_APP/Contents/MacOS/BruTV" \
    "$ARM_APP/Contents/MacOS/BruTV" "$X86_APP/Contents/MacOS/BruTV"
  if [[ -e "$OUTPUT/xtool/BruTV.app" ]]; then
    mv "$OUTPUT/xtool/BruTV.app" "$OUTPUT/xtool/BruTV.app.previous.$(date +%s)"
  fi
  mv "$TEMP_APP" "$OUTPUT/xtool/BruTV.app"
  chmod +x "$OUTPUT/xtool/BruTV.app/Contents/MacOS/BruTV"
else
  build "$OUTPUT" arm64-apple-ios
  [[ -f "$OUTPUT/xtool/BruTV.app/BruTV" ]] || { echo "error: xtool did not produce the BruTV app executable" >&2; exit 1; }
fi
echo "app: $OUTPUT/xtool/BruTV.app"
if [[ "$CONFIGURATION" = release ]]; then
  SYMBOL_BINARY="$OUTPUT/xtool/BruTV.app/BruTV"
  if [[ "$PLATFORM" = macos ]]; then
    SYMBOL_BINARY="$OUTPUT/xtool/BruTV.app/Contents/MacOS/BruTV"
  fi
  SYMBOL_STAGE="$(mktemp -d "$OUTPUT/xtool/.symbols.XXXXXX")"
  if [[ "$PLATFORM" = macos ]]; then
    # Linking each architecture separately avoids dsymutil's external lipo dependency.
    mkdir -p "$SYMBOL_STAGE/arm64" "$SYMBOL_STAGE/x86_64"
    ARM_SYMBOLS="$SYMBOL_STAGE/arm64/BruTV.app.dSYM"
    X86_SYMBOLS="$SYMBOL_STAGE/x86_64/BruTV.app.dSYM"
    "$DSYMUTIL" --num-threads "${IOS_BUILD_JOBS:-4}" "$ARM_APP/Contents/MacOS/BruTV" \
      --out "$ARM_SYMBOLS"
    "$DSYMUTIL" --num-threads "${IOS_BUILD_JOBS:-4}" "$X86_APP/Contents/MacOS/BruTV" \
      --out "$X86_SYMBOLS"
    cmp -s "$ARM_SYMBOLS/Contents/Info.plist" "$X86_SYMBOLS/Contents/Info.plist" || {
      echo "error: Catalyst dSYM metadata differs between architectures" >&2
      exit 1
    }
    mkdir -p "$SYMBOL_STAGE/BruTV.app.dSYM"
    cp -a "$ARM_SYMBOLS/." "$SYMBOL_STAGE/BruTV.app.dSYM/"
    cp -a "$X86_SYMBOLS/Contents/Resources/." \
      "$SYMBOL_STAGE/BruTV.app.dSYM/Contents/Resources/"
    "$RCODESIGN" -C /dev/null macho-universal-create \
      --output "$SYMBOL_STAGE/BruTV.app.dSYM/Contents/Resources/DWARF/BruTV" \
      "$ARM_SYMBOLS/Contents/Resources/DWARF/BruTV" \
      "$X86_SYMBOLS/Contents/Resources/DWARF/BruTV"
  else
    "$DSYMUTIL" --num-threads "${IOS_BUILD_JOBS:-4}" "$SYMBOL_BINARY" \
      --out "$SYMBOL_STAGE/BruTV.app.dSYM"
  fi
  [[ -s "$SYMBOL_STAGE/BruTV.app.dSYM/Contents/Resources/DWARF/BruTV" ]] || {
    echo "error: dsymutil did not produce BruTV's crash symbols" >&2
    exit 1
  }
  if [[ -e "$OUTPUT/xtool/BruTV.app.dSYM" ]]; then
    mv "$OUTPUT/xtool/BruTV.app.dSYM" "$SYMBOL_STAGE/previous.dSYM"
  fi
  mv "$SYMBOL_STAGE/BruTV.app.dSYM" "$OUTPUT/xtool/BruTV.app.dSYM"
  echo "dsym: $OUTPUT/xtool/BruTV.app.dSYM"
fi

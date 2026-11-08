#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${1:?Usage: linux-toolchain.sh swift|xtool [arguments]}"
shift
case "$TOOL" in swift|xtool) ;; *) echo "error: unsupported tool: $TOOL" >&2; exit 2 ;; esac

LLVM_TOOLS_DIR="${BRUTV_LLVM_TOOLS_DIR:-$SCRIPT_DIR/build/tools/llvm}"
if [[ -z "${XTOOL_LD64_LLD:-}" && -x "$LLVM_TOOLS_DIR/bin/ld64.lld" ]]; then
  export XTOOL_LD64_LLD="$LLVM_TOOLS_DIR/bin/ld64.lld"
fi

if [[ "$TOOL" == swift ]] && command -v swift >/dev/null 2>&1; then
  exec swift "$@"
fi

EXPLICIT_XTOOL_SOURCE_DIR="${XTOOL_SOURCE_DIR:-}"
XTOOL_SOURCE_DIR="${XTOOL_SOURCE_DIR:-$SCRIPT_DIR/../../../../xtool}"
if [[ "$TOOL" == xtool && -z "$EXPLICIT_XTOOL_SOURCE_DIR" ]] && \
  command -v swift >/dev/null 2>&1 && command -v xtool >/dev/null 2>&1; then
  exec "$TOOL" "$@"
fi

if [[ "$TOOL" == xtool && -n "$EXPLICIT_XTOOL_SOURCE_DIR" ]]; then
  [[ -f "$XTOOL_SOURCE_DIR/Package.swift" ]] || {
    echo "error: XTOOL_SOURCE_DIR does not contain Package.swift: $XTOOL_SOURCE_DIR" >&2
    exit 1
  }
  XTOOL_SOURCE_DIR="$(cd "$XTOOL_SOURCE_DIR" && pwd)"
  if command -v swift >/dev/null 2>&1; then
    TOOLS_DIR="${BRUTV_TOOLS_DIR:-$SCRIPT_DIR/build/linux-tools}"
    mkdir -p "$TOOLS_DIR"
    TOOLS_DIR="$(cd "$TOOLS_DIR" && pwd)"
    mkdir -p "$XTOOL_SOURCE_DIR/.build"
    exec {HOST_BUILD_LOCK}>"$XTOOL_SOURCE_DIR/.build/brutv-host-build.lock"
    flock "$HOST_BUILD_LOCK"
    if ! swift build --package-path "$XTOOL_SOURCE_DIR" --build-system native \
        --jobs "${BRUTV_BUILD_JOBS:-4}" --product xtool > "$TOOLS_DIR/xtool-host-build.log" 2>&1; then
      tail -n 80 "$TOOLS_DIR/xtool-host-build.log" >&2
      exit 1
    fi
    flock -u "$HOST_BUILD_LOCK"
    exec {HOST_BUILD_LOCK}>&-
    XTOOL_BINARY="$XTOOL_SOURCE_DIR/.build/debug/xtool"
    [[ -x "$XTOOL_BINARY" ]] || {
      echo "error: xtool build did not produce an executable at $XTOOL_BINARY" >&2
      exit 1
    }
    exec "$XTOOL_BINARY" "$@"
  fi
fi

command -v docker >/dev/null 2>&1 || {
  echo "error: install Swift and xtool, or Docker for the bundled Swift toolchain" >&2
  exit 1
}

TOOLS_DIR="${BRUTV_TOOLS_DIR:-$SCRIPT_DIR/build/linux-tools}"
mkdir -p "$TOOLS_DIR/home/.swiftpm" "$TOOLS_DIR/home/.cache" "$TOOLS_DIR/home/.config"
TOOLS_DIR="$(cd "$TOOLS_DIR" && pwd)"
DOCKER_ARGS=(run --rm --cpus "${BRUTV_BUILD_JOBS:-4}" --memory 8g --user "$(id -u):$(id -g)" -w "$PWD"
  -v "$SCRIPT_DIR:$SCRIPT_DIR" -v "$TOOLS_DIR:$TOOLS_DIR"
  -v "$TOOLS_DIR/home:$HOME" -e "HOME=$HOME" -e "XDG_CONFIG_HOME=$TOOLS_DIR/home/.config"
  -e BRUTV_XTOOL -e BRUTV_XTOOL_PLATFORM -e BRUTV_XTOOL_DEPLOYMENT_TARGET
  -e IOS_BUNDLE_ID -e IOS_BUILD_NUMBER -e IOS_MARKETING_VERSION -e IOS_DARWIN_SDK_PATH
  -e TVOS_BUNDLE_ID -e TVOS_TOPSHELF_BUNDLE_ID
  -e XTOOL_LD64_LLD)
declare -A MOUNTED=(["$SCRIPT_DIR"]=1 ["$TOOLS_DIR"]=1 ["$HOME"]=1)
if [[ "$PWD" != "$SCRIPT_DIR" && "$PWD" != "$SCRIPT_DIR/"* && -z "${MOUNTED[$PWD]:-}" ]]; then
  DOCKER_ARGS+=(-v "$PWD:$PWD")
  MOUNTED["$PWD"]=1
fi
if [[ -d "$XTOOL_SOURCE_DIR" ]]; then
  XTOOL_SOURCE_DIR="$(cd "$XTOOL_SOURCE_DIR" && pwd)"
  DOCKER_ARGS+=(-v "$XTOOL_SOURCE_DIR:$XTOOL_SOURCE_DIR")
  MOUNTED["$XTOOL_SOURCE_DIR"]=1
fi
if [[ -n "${XTOOL_LD64_LLD:-}" ]]; then
  # Preserve the ld64.lld alias: lld chooses the Mach-O driver from its filename.
  XTOOL_LD64_LLD="$(realpath -s "$XTOOL_LD64_LLD")"
  export XTOOL_LD64_LLD
  LINKER_BIN_DIR="$(dirname "$XTOOL_LD64_LLD")"
  for directory in "$LINKER_BIN_DIR" "$(dirname "$LINKER_BIN_DIR")/lib"; do
    if [[ -d "$directory" && -z "${MOUNTED[$directory]:-}" && "$directory" != "$SCRIPT_DIR/"* && "$directory" != "$TOOLS_DIR/"* ]]; then
      DOCKER_ARGS+=(-v "$directory:$directory:ro")
      MOUNTED["$directory"]=1
    fi
  done
fi
for input in "$@" "${IOS_DARWIN_SDK_PATH:-}"; do
  if [[ "$input" == /* && -e "$input" && "$input" != "${XCODE_XIP_PATH:-}" && -z "${MOUNTED[$input]:-}" && "$input" != "$SCRIPT_DIR/"* && "$input" != "$TOOLS_DIR/"* && "$input" != "$PWD/"* ]]; then
    DOCKER_ARGS+=(-v "$input:$input")
    MOUNTED["$input"]=1
  fi
done
if [[ -n "${XCODE_XIP_PATH:-}" ]]; then
  [[ -e "$XCODE_XIP_PATH" ]] || { echo "error: XCODE_XIP_PATH does not exist" >&2; exit 1; }
  DOCKER_ARGS+=(-v "$XCODE_XIP_PATH:$XCODE_XIP_PATH:ro")
fi
IMAGE="${BRUTV_SWIFT_IMAGE:-swift:6.4.0-noble}"
if [[ "$TOOL" == swift ]]; then
  exec docker "${DOCKER_ARGS[@]}" "$IMAGE" swift "$@"
fi
[[ -f "$XTOOL_SOURCE_DIR/Package.swift" ]] || {
  echo "error: xtool is missing. Set XTOOL_BINARY, or XTOOL_SOURCE_DIR to the tested xtool fork checkout." >&2
  exit 1
}
IMAGE="${BRUTV_XTOOL_IMAGE:-brutv-xtool-dev:6.4}"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  [[ -f "$XTOOL_SOURCE_DIR/Dockerfile" ]] || { echo "error: xtool checkout has no Dockerfile" >&2; exit 1; }
  # Keep the upstream Dockerfile's build argument literal while choosing its Noble base.
  # shellcheck disable=SC2016
  sed 's/${SWIFT_VERSION}-jammy/${SWIFT_VERSION}-noble/' "$XTOOL_SOURCE_DIR/Dockerfile" | \
    docker build --target build-xtool-base --build-arg SWIFT_VERSION=6.4.0 \
      --tag "$IMAGE" --file - "$XTOOL_SOURCE_DIR"
fi
DOCKER_ARGS+=(-v "$XTOOL_SOURCE_DIR:/src")
command -v flock >/dev/null || { echo "error: flock is required to serialize xtool host builds" >&2; exit 1; }
mkdir -p "$XTOOL_SOURCE_DIR/.build"
exec {HOST_BUILD_LOCK}>"$XTOOL_SOURCE_DIR/.build/brutv-host-build.lock"
flock "$HOST_BUILD_LOCK"
if ! docker "${DOCKER_ARGS[@]}" "$IMAGE" swift build --package-path /src --build-system native \
    --jobs "${BRUTV_BUILD_JOBS:-4}" --product xtool > "$TOOLS_DIR/xtool-host-build.log" 2>&1; then
  tail -n 80 "$TOOLS_DIR/xtool-host-build.log" >&2
  exit 1
fi
flock -u "$HOST_BUILD_LOCK"
exec {HOST_BUILD_LOCK}>&-
exec docker "${DOCKER_ARGS[@]}" "$IMAGE" /src/.build/debug/xtool "$@"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVISION=614caa8d1ca949e260e5746144aa52d27a4b08d6
TOOLS_DIR="${BRUTV_SIGNING_TOOLS_DIR:-$SCRIPT_DIR/build/tools}"
MODE="${BRUTV_ZSIGN_BUILD_MODE:-auto}"

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  cat <<'USAGE'
Usage: setup-zsign.sh

Build pinned zsign into build/tools/bin/zsign without installing system packages.
Uses a native C++/OpenSSL toolchain when available, otherwise Docker. Docker
builds reuse BRUTV_XTOOL_IMAGE (default: brutv-xtool-dev:6.4) when it exists.

Optional environment:
  BRUTV_SIGNING_TOOLS_DIR  Private installation directory (default: build/tools)
  BRUTV_ZSIGN_BUILD_MODE   auto, native, or docker (default: auto)
  BRUTV_ZSIGN_IMAGE        Existing Docker image with make, C++, and OpenSSL
  BRUTV_BUILD_JOBS         Parallel compiler jobs (default: 4)
  IOS_ZSIGN               Set this to use a different signer in release scripts
USAGE
  exit 0
fi
[[ $# -eq 0 ]] || { echo "error: setup-zsign.sh takes no arguments" >&2; exit 2; }
[[ "$(uname -s)" == Linux ]] || { echo "error: setup-zsign.sh requires Linux" >&2; exit 1; }
case "$MODE" in auto|native|docker) ;; *) echo "error: BRUTV_ZSIGN_BUILD_MODE must be auto, native, or docker" >&2; exit 2 ;; esac
command -v git >/dev/null 2>&1 || { echo "error: required command not found: git" >&2; exit 1; }

NATIVE=true
for tool in g++ cc make pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || NATIVE=false
done
if [[ "$NATIVE" == true ]] && ! pkg-config --exists openssl; then
  NATIVE=false
fi
if [[ "$MODE" == native && "$NATIVE" != true ]]; then
  echo "error: native zsign requires g++, cc, make, pkg-config, and OpenSSL development files; use BRUTV_ZSIGN_BUILD_MODE=docker" >&2
  exit 1
fi
if [[ "$MODE" == auto ]]; then
  if [[ "$NATIVE" == true ]]; then MODE=native; else MODE=docker; fi
fi

mkdir -p "$TOOLS_DIR/bin" "$TOOLS_DIR/libexec"
TOOLS_DIR="$(cd "$TOOLS_DIR" && pwd)"
WORK="$(mktemp -d "$TOOLS_DIR/.zsign-build-XXXXXXXX")"
cleanup() { rm -rf "$WORK"; rm -f "$TOOLS_DIR/libexec/.zsign-$$"; }
trap cleanup EXIT

git -C "$WORK" init --quiet
git -C "$WORK" remote add origin https://github.com/zhlynn/zsign.git
git -C "$WORK" fetch --quiet --depth=1 --no-tags origin "$REVISION"
git -C "$WORK" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
[[ "$(git -C "$WORK" rev-parse HEAD)" == "$REVISION" ]] || { echo "error: zsign source revision does not match the pinned commit" >&2; exit 1; }
git -C "$WORK" apply --check "$SCRIPT_DIR/linux-tools/patches/zsign-profile-entitlements.patch"
git -C "$WORK" apply "$SCRIPT_DIR/linux-tools/patches/zsign-profile-entitlements.patch"

if [[ "$MODE" == native ]]; then
  make -s -C "$WORK/build/linux" -j "${BRUTV_BUILD_JOBS:-4}" VERSION=1.1.2-brutv1
  install -m 755 "$WORK/bin/zsign" "$WORK/zsign-installed"
  "$WORK/zsign-installed" --version
  mv -f "$WORK/zsign-installed" "$TOOLS_DIR/bin/zsign"
else
  command -v docker >/dev/null 2>&1 || { echo "error: native dependencies unavailable; install Docker or provide IOS_ZSIGN" >&2; exit 1; }
  IMAGE="${BRUTV_ZSIGN_IMAGE:-${BRUTV_XTOOL_IMAGE:-brutv-xtool-dev:6.4}}"
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    if [[ -n "${BRUTV_ZSIGN_IMAGE:-}" ]]; then
      echo "error: BRUTV_ZSIGN_IMAGE must name an available Docker image" >&2
      exit 1
    fi
    IMAGE=brutv-zsign-dev:1.1.2
    docker build --tag "$IMAGE" --file - "$WORK" <<'DOCKERFILE'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends g++ gcc make pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
DOCKERFILE
  fi
  docker run --rm --user "$(id -u):$(id -g)" \
    -v "$WORK:$WORK" -w "$WORK/build/linux" "$IMAGE" \
    make -s -j "${BRUTV_BUILD_JOBS:-4}" VERSION=1.1.2-brutv1
  install -m 755 "$WORK/bin/zsign" "$TOOLS_DIR/libexec/.zsign-$$"
  docker run --rm --network none --user "$(id -u):$(id -g)" \
    -v "$TOOLS_DIR/libexec:$TOOLS_DIR/libexec:ro" "$IMAGE" "$TOOLS_DIR/libexec/.zsign-$$" --version
  mv -f "$TOOLS_DIR/libexec/.zsign-$$" "$TOOLS_DIR/libexec/zsign"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\nIMAGE=%q\n' "$IMAGE"
    cat <<'WRAPPER'
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGS=(run --rm --network none --user "$(id -u):$(id -g)" -w "$PWD"
  -v "$PWD:$PWD" -v "$TOOLS_DIR/libexec:$TOOLS_DIR/libexec:ro")
for input in "$@"; do
  if [[ "$input" == /* && -e "$input" && "$input" != "$PWD" && "$input" != "$PWD/"* && "$input" != "$TOOLS_DIR/libexec/"* ]]; then
    if [[ -d "$input" ]]; then ARGS+=(-v "$input:$input"); else ARGS+=(-v "$input:$input:ro"); fi
  fi
done
exec docker "${ARGS[@]}" "$IMAGE" "$TOOLS_DIR/libexec/zsign" "$@"
WRAPPER
  } > "$WORK/zsign-wrapper"
  chmod 755 "$WORK/zsign-wrapper"
  mv -f "$WORK/zsign-wrapper" "$TOOLS_DIR/bin/zsign"
fi
"$TOOLS_DIR/bin/zsign" --version
printf 'Installed zsign %s (%s toolchain): %s\n' "$REVISION" "$MODE" "$TOOLS_DIR/bin/zsign"

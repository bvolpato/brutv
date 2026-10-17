#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=23.1.3
case "$(uname -sm)" in
  'Linux x86_64')
    ARCH=X64
    SHA256=14d2f701eb68fb799001bdea6231048f3990690fa2f406d563555ff8f744daba
    ;;
  'Linux aarch64'|'Linux arm64')
    ARCH=ARM64
    SHA256=1154f37ec15b5654fcb8cc3a8a2352a4cc4eef44bdff7ddd47fb10ea85c82f01
    ;;
  *) echo 'error: the pinned Catalyst linker supports Linux x86_64 and arm64' >&2; exit 1 ;;
esac

DESTINATION="${BRUTV_LLVM_TOOLS_DIR:-$SCRIPT_DIR/build/tools/llvm}"
if [[ -x "$DESTINATION/bin/ld64.lld" ]] && [[ "$("$DESTINATION/bin/ld64.lld" --version)" == "LLD $VERSION"* ]]; then
  echo "Catalyst linker: $DESTINATION/bin/ld64.lld"
  exit 0
fi
for tool in curl sha256sum tar zstd; do
  command -v "$tool" >/dev/null || { echo "error: $tool is required to install the Catalyst linker" >&2; exit 1; }
done

PARENT="$(dirname "$DESTINATION")"
mkdir -p "$PARENT"
PARENT="$(cd "$PARENT" && pwd)"
DESTINATION="$PARENT/$(basename "$DESTINATION")"
NAME="LLVM-$VERSION-Linux-$ARCH"
ARCHIVE="${BRUTV_LLVM_ARCHIVE:-$PARENT/cache/$NAME.tar.zst}"
if [[ ! -f "$ARCHIVE" ]]; then
  [[ -z "${BRUTV_LLVM_ARCHIVE:-}" ]] || { echo 'error: BRUTV_LLVM_ARCHIVE is not a readable archive' >&2; exit 1; }
  mkdir -p "$(dirname "$ARCHIVE")"
  curl --fail --location --retry 3 \
    "https://github.com/llvm/llvm-project/releases/download/llvmorg-$VERSION/$NAME.tar.zst" \
    --output "$ARCHIVE.part"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | sha256sum --check --status || {
  echo 'error: LLVM archive SHA-256 does not match the pinned official release' >&2
  exit 1
}

STAGE="$(mktemp -d "$PARENT/.llvm.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
# Official LLVM archives use a 1 GiB zstd window. Only the Mach-O linker is needed.
tar --use-compress-program='zstd -d --long=30' --extract --file "$ARCHIVE" \
  --directory "$STAGE" --strip-components=1 --no-same-owner \
  "$NAME/bin/lld" "$NAME/bin/ld64.lld"
[[ "$("$STAGE/bin/ld64.lld" --version)" == "LLD $VERSION"* ]] || {
  echo 'error: the extracted LLVM linker cannot run on this host' >&2
  exit 1
}
if [[ -e "$DESTINATION" ]]; then
  PREVIOUS="$(mktemp -d "$PARENT/.llvm-previous.XXXXXX")"
  mv "$DESTINATION" "$PREVIOUS/llvm"
  echo "Previous linker preserved: $PREVIOUS/llvm"
fi
mv "$STAGE" "$DESTINATION"
trap - EXIT
echo "Catalyst linker: $DESTINATION/bin/ld64.lld"

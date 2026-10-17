#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="${BRUTV_MAC_TOOLS_DIR:-$SCRIPT_DIR/build/tools}"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo "Usage: setup-mac-tools.sh [--prefix DIRECTORY]"
  echo "Installs pinned Linux rcodesign, mkbom, lsbom, and xar into build/tools/bin."
  echo "Uses private downloads/builds. Missing Debian/Ubuntu development headers are extracted locally."
  exit 0
fi
if [[ "${1:-}" == --prefix && $# == 2 ]]; then
  TOOLS_DIR="$2"
elif [[ $# != 0 ]]; then
  echo "error: expected --prefix DIRECTORY or no arguments" >&2
  exit 2
fi
[[ "$(uname -s)" == Linux ]] || { echo "error: this bootstrap targets Linux" >&2; exit 1; }
for required in curl sha256sum tar make cc c++ autoconf sed gzip cpio openssl; do
  command -v "$required" >/dev/null || { echo "error: required command not found: $required" >&2; exit 1; }
done
mkdir -p "$TOOLS_DIR"
TOOLS_DIR="$(cd "$TOOLS_DIR" && pwd)"
WORK_DIR="$(mktemp -d "$TOOLS_DIR/.mac-tools-build.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

fetch() {
  local url="$1" digest="$2" output="$3"
  curl --fail --location --silent --show-error --proto '=https' "$url" -o "$output"
  printf '%s  %s\n' "$digest" "$output" | sha256sum --check --status || {
    echo "error: downloaded source checksum mismatch: $url" >&2
    exit 1
  }
}

smoke() {
  local directory="$1"
  "$directory/rcodesign" --version | rg -q '^apple-codesign 0\.29\.0$'
  mkdir -p "$WORK_DIR/smoke/App.app/Contents"
  printf 'installer payload\n' > "$WORK_DIR/smoke/App.app/Contents/probe"
  "$directory/mkbom" -u 0 -g 80 "$WORK_DIR/smoke" "$WORK_DIR/Bom"
  "$directory/lsbom" -s "$WORK_DIR/Bom" | rg -q '^\./App\.app/Contents/probe$'
  "$directory/xar" --compression none -cf "$WORK_DIR/probe.pkg" -C "$WORK_DIR" Bom
  "$directory/xar" -tf "$WORK_DIR/probe.pkg" | rg -q '^Bom$'
}

command -v rg >/dev/null || { echo "error: required command not found: rg" >&2; exit 1; }
if [[ -x "$TOOLS_DIR/bin/rcodesign" && -x "$TOOLS_DIR/bin/mkbom" && -x "$TOOLS_DIR/bin/lsbom" && -x "$TOOLS_DIR/bin/xar" ]]; then
  smoke "$TOOLS_DIR/bin"
  echo "Mac release tools verified: $TOOLS_DIR/bin"
  exit 0
fi

case "$(uname -m)" in
  x86_64) RCODESIGN_ARCH=x86_64; RCODESIGN_SHA=dbe85cedd8ee4217b64e9a0e4c2aef92ab8bcaaa41f20bde99781ff02e600002 ;;
  aarch64|arm64) RCODESIGN_ARCH=aarch64; RCODESIGN_SHA=4af92c87ddf52f5f2d1258a3b4e56c7dcb8f1b2468df744976c5f139e031961f ;;
  *) echo "error: pinned rcodesign releases support Linux x86_64 and aarch64" >&2; exit 1 ;;
esac
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/rcodesign" "$WORK_DIR/bomutils" "$WORK_DIR/xar"
RCODESIGN_ASSET="apple-codesign-0.29.0-$RCODESIGN_ARCH-unknown-linux-musl"
fetch "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/0.29.0/$RCODESIGN_ASSET.tar.gz" "$RCODESIGN_SHA" "$WORK_DIR/rcodesign.tar.gz"
tar -xf "$WORK_DIR/rcodesign.tar.gz" -C "$WORK_DIR/rcodesign" --strip-components=1
install -m 0755 "$WORK_DIR/rcodesign/rcodesign" "$WORK_DIR/bin/rcodesign"

BOM_REV=c247002e2f49878bab32dd0fcf805810ae0992cb
fetch "https://codeload.github.com/hogliux/bomutils/tar.gz/$BOM_REV" 286e49560a3f84650b5a60ca0f22f775c0526aa4fb199db7a66f4d310378d4dd "$WORK_DIR/bomutils.tar.gz"
tar -xf "$WORK_DIR/bomutils.tar.gz" -C "$WORK_DIR/bomutils" --strip-components=1
# The pinned upstream lsbom commit inverts the Paths comparison and segfaults.
sed -i 's/strstr(name.c_str(),"Paths") == 0/name == "Paths"/' "$WORK_DIR/bomutils/src/lsbom.cpp"
make -C "$WORK_DIR/bomutils" -j "${BRUTV_BUILD_JOBS:-4}" CXX="${CXX:-c++}" CXXFLAGS='-O2 -std=c++11' CFLAGS='-O2' > "$WORK_DIR/bomutils-build.log" 2>&1 || {
  cat "$WORK_DIR/bomutils-build.log" >&2; exit 1;
}
install -m 0755 "$WORK_DIR/bomutils/build/bin/mkbom" "$WORK_DIR/bomutils/build/bin/lsbom" "$WORK_DIR/bin/"

XAR_REV=66d451dab1ef859dd0c83995f2379335d35e53c9
fetch "https://codeload.github.com/mackyle/xar/tar.gz/$XAR_REV" 891a1ee71369e535c9b302ab20fb94dac40fcf30f1951749e238334689454c02 "$WORK_DIR/xar.tar.gz"
tar -xf "$WORK_DIR/xar.tar.gz" -C "$WORK_DIR/xar" --strip-components=1
# OpenSSL 1.1 and later expose initialization through OPENSSL_init_crypto.
sed -i 's/OpenSSL_add_all_ciphers/OPENSSL_init_crypto/g' "$WORK_DIR/xar/xar/configure.ac"
XML_CONFIG="$(command -v xml2-config || true)"
EXTRA_CPPFLAGS="${CPPFLAGS:-}"
EXTRA_LDFLAGS="${LDFLAGS:-}"
if [[ -z "$XML_CONFIG" ]] || ! printf '#include <openssl/evp.h>\n' | "${CC:-cc}" -E -x c - >/dev/null 2>&1; then
  for required in apt-get dpkg-deb ldconfig; do
    command -v "$required" >/dev/null || {
      echo "error: xar needs libxml2 and OpenSSL development headers. Install them with your distribution's package manager or provide CPPFLAGS/LDFLAGS and xml2-config." >&2
      exit 1
    }
  done
  mkdir -p "$WORK_DIR/dependencies"
  (
    cd "$WORK_DIR/dependencies"
    apt-get download libxml2-dev libssl-dev
    for archive in *.deb; do dpkg-deb -x "$archive" root; done
  )
  DEPS="$WORK_DIR/dependencies/root/usr"
  MULTIARCH="$("${CC:-cc}" -print-multiarch)"
  for library in libxml2 libcrypto libssl; do
    RUNTIME="$(ldconfig -p | awk -v name="$library.so" '$1 ~ ("^" name "\\.") {print $NF; exit}')"
    [[ -n "$RUNTIME" && -f "$RUNTIME" ]] || { echo "error: missing runtime library: $library" >&2; exit 1; }
    ln -sf "$RUNTIME" "$DEPS/lib/$MULTIARCH/$library.so"
  done
  XML_CONFIG="$DEPS/bin/xml2-config"
  EXTRA_CPPFLAGS="$EXTRA_CPPFLAGS -I$DEPS/include -I$DEPS/include/libxml2 -I$DEPS/include/$MULTIARCH"
  EXTRA_LDFLAGS="$EXTRA_LDFLAGS -L$DEPS/lib/$MULTIARCH"
fi
(
  cd "$WORK_DIR/xar/xar"
  CPPFLAGS="$EXTRA_CPPFLAGS" LDFLAGS="$EXTRA_LDFLAGS" ./autogen.sh --prefix="$TOOLS_DIR" --with-xml2-config="$XML_CONFIG" --disable-shared
  make -j "${BRUTV_BUILD_JOBS:-4}" src/xar
) > "$WORK_DIR/xar-build.log" 2>&1 || { cat "$WORK_DIR/xar-build.log" >&2; exit 1; }
install -m 0755 "$WORK_DIR/xar/xar/src/xar" "$WORK_DIR/bin/xar"
smoke "$WORK_DIR/bin"
mkdir -p "$TOOLS_DIR/bin"
for executable in rcodesign mkbom lsbom xar; do
  install -m 0755 "$WORK_DIR/bin/$executable" "$TOOLS_DIR/bin/.$executable.new"
  mv "$TOOLS_DIR/bin/.$executable.new" "$TOOLS_DIR/bin/$executable"
done
echo "Mac release tools installed and verified: $TOOLS_DIR/bin"

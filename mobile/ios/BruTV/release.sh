#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(uname -s)" == "Linux" ]]; then
  command -v uv >/dev/null 2>&1 || { echo "error: Linux releases require uv" >&2; exit 1; }
  exec uv run "$SCRIPT_DIR/release-linux.py" "$@"
fi
source "$SCRIPT_DIR/apple-sdk.sh"

PLATFORM=all
SKIP_SIM_BUILD=false
UPLOAD=false
PREFLIGHT=false
PLIST_BUDDY="${PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
BUILD_DIR="${IOS_RELEASE_DIR:-$SCRIPT_DIR/build/release}"
PROFILE_DIR="${BRUTV_PROVISIONING_PROFILE_DIR:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles}"
BUNDLE_ID="${IOS_BUNDLE_ID:-com.bvolpato.brutv}"
EXPORT_METHOD="${IOS_EXPORT_METHOD:-app-store-connect}"
CODE_SIGN_IDENTITY="${IOS_CODE_SIGN_IDENTITY:-Apple Distribution}"
KEYCHAIN_CREATED=false
CERTIFICATE_COUNT=0
ORIGINAL_KEYCHAINS=()
IMPORTED_CERTIFICATES=()

usage() {
  cat <<'USAGE'
Usage: mobile/ios/BruTV/release.sh [--platform ios|macos|tvos|all] [--skip-simulator-build] [--preflight] [--upload]

Build and export each requested Apple platform before any optional upload.
macOS uses Xcode; Linux dispatches to the xtool release helper.

Options:
  --platform               Requested platform, default: all.
  --skip-simulator-build   Skip the requested platform's simulator build.
  --preflight              Check tools, signing inputs, and target mappings without building or uploading.
  --upload                 Upload only after every requested package has exported successfully.

Signing:
  IOS_SIGNING=automatic uses the configured Xcode account and keychain identities.
  IOS_SIGNING=manual imports distribution certificates into a temporary keychain.
  iOS/tvOS: IOS_CERTIFICATE_PATH and IOS_P12_PASSWORD.
  Profiles: IOS_PROVISIONING_PROFILE_PATH, MACOS_PROVISIONING_PROFILE_PATH,
            TVOS_PROVISIONING_PROFILE_PATH, TVOS_TOPSHELF_PROVISIONING_PROFILE_PATH.
  Catalyst: MACOS_APPLICATION_CERTIFICATE_PATH / MACOS_APPLICATION_P12_PASSWORD
            and MACOS_INSTALLER_CERTIFICATE_PATH / MACOS_INSTALLER_P12_PASSWORD,
            or compatible identities already in the keychain.
  Certificate/profile inputs also accept _BASE64 instead of _PATH.
  IOS_TEAM_ID, IOS_BUNDLE_ID, IOS_BUILD_NUMBER, IOS_MARKETING_VERSION,
  IOS_EXPORT_METHOD and IOS_RELEASE_DIR override their corresponding defaults.
  MACOS_CODE_SIGN_IDENTITY selects a legacy Mac App Distribution identity.
  With no explicit inputs, the local ignored signing/ iOS files are used.

Each run preserves earlier artifacts in build/release and prints its export paths.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      [[ $# -ge 2 ]] || { echo "error: --platform requires a value" >&2; exit 2; }
      PLATFORM="$2"; shift 2 ;;
    --skip-simulator-build) SKIP_SIM_BUILD=true; shift ;;
    --preflight) PREFLIGHT=true; shift ;;
    --upload) UPLOAD=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$PLATFORM" in
  all) PLATFORMS=(ios macos tvos) ;;
  ios|macos|tvos) PLATFORMS=("$PLATFORM") ;;
  *) echo "error: unsupported Apple platform: $PLATFORM" >&2; exit 2 ;;
esac

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: required command not found: $1" >&2; exit 1; }
}
require_env() {
  printenv "$1" >/dev/null || { echo "error: required environment variable '$1' is not set" >&2; exit 1; }
}
cleanup() {
  if [[ "$KEYCHAIN_CREATED" = true ]]; then
    security list-keychains -d user -s ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"} >/dev/null 2>&1 || true
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  fi
  [[ -z "${SIGNING_DIR:-}" ]] || rm -rf "$SIGNING_DIR"
}
trap cleanup EXIT

[[ "$(uname -s)" == Darwin ]] || { echo "error: Apple release builds require macOS with Xcode" >&2; exit 1; }
for tool in xcodebuild security xcrun sips openssl "$PLIST_BUDDY"; do require_cmd "$tool"; done
# Apple's export step requires the system rsync rather than Homebrew's version.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Xcode.app/Contents/Developer/usr/bin:$PATH"
export LC_ALL=C
for platform in "${PLATFORMS[@]}"; do
  case "$platform" in
    ios)
      brutv_require_xcode_sdk iphoneos
      [[ "$SKIP_SIM_BUILD" == true ]] || brutv_require_xcode_sdk iphonesimulator ;;
    tvos)
      brutv_require_xcode_sdk appletvos
      [[ "$SKIP_SIM_BUILD" == true ]] || brutv_require_xcode_sdk appletvsimulator ;;
    macos) brutv_require_xcode_sdk macosx ;;
  esac
done
mkdir -p "$BUILD_DIR" "$PROFILE_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
RUN_DIR="$(mktemp -d "$BUILD_DIR/run.XXXXXX")"
SIGNING_DIR="$RUN_DIR/signing"
mkdir -m 700 "$SIGNING_DIR"
KEYCHAIN_PATH="$SIGNING_DIR/brutv-release.keychain-db"
umask 077

input_file() {
  local prefix="$1" suffix="$2" path_name="${1}_PATH" base64_name="${1}_BASE64" output
  output="${!path_name:-}"
  if [[ -n "${!base64_name:-}" ]]; then
    output="$SIGNING_DIR/$prefix$suffix"
    if base64 --help >/dev/null 2>&1; then
      printf '%s' "${!base64_name}" | base64 --decode > "$output"
    else
      printf '%s' "${!base64_name}" | base64 -D > "$output"
    fi
  fi
  printf '%s\n' "$output"
}

CERT_PATH="$(input_file IOS_CERTIFICATE .p12)"
IOS_PROFILE_PATH="$(input_file IOS_PROVISIONING_PROFILE .mobileprovision)"
if [[ "${IOS_SIGNING:-}" != automatic ]]; then
  if [[ -z "$CERT_PATH" ]]; then
    CERT_PATH="$(find "$SCRIPT_DIR/signing" -maxdepth 1 -name '*.p12' -type f 2>/dev/null | sort | head -n 1 || true)"
  fi
  if [[ -z "$IOS_PROFILE_PATH" ]]; then
    IOS_PROFILE_PATH="$(find "$SCRIPT_DIR/signing" -maxdepth 1 -name '*.mobileprovision' -type f 2>/dev/null | sort | head -n 1 || true)"
  fi
fi
SIGNING_MODE="${IOS_SIGNING:-}"
if [[ -z "$SIGNING_MODE" ]]; then
  if [[ -n "$CERT_PATH$IOS_PROFILE_PATH${MACOS_PROVISIONING_PROFILE_PATH:-}${TVOS_PROVISIONING_PROFILE_PATH:-}${MACOS_PROVISIONING_PROFILE_BASE64:-}${TVOS_PROVISIONING_PROFILE_BASE64:-}${MACOS_APPLICATION_CERTIFICATE_PATH:-}${MACOS_APPLICATION_CERTIFICATE_BASE64:-}${MACOS_INSTALLER_CERTIFICATE_PATH:-}${MACOS_INSTALLER_CERTIFICATE_BASE64:-}${TVOS_TOPSHELF_PROVISIONING_PROFILE_PATH:-}${TVOS_TOPSHELF_PROVISIONING_PROFILE_BASE64:-}" ]]; then
    SIGNING_MODE=manual
  else
    SIGNING_MODE=automatic
  fi
fi
[[ "$SIGNING_MODE" == manual || "$SIGNING_MODE" == automatic ]] || { echo "error: IOS_SIGNING must be manual or automatic" >&2; exit 2; }
TEAM_ID="${IOS_TEAM_ID:-}"
echo "signing: $SIGNING_MODE"

read_profile() {
  local prefix="$1" platform="$2" bundle="$3" path="$4" decoded uuid team identifier development devices expiration
  [[ -n "$path" && -f "$path" ]] || { echo "error: missing $prefix provisioning profile" >&2; exit 1; }
  decoded="$SIGNING_DIR/$prefix.plist"
  security cms -D -i "$path" > "$decoded"
  uuid="$("$PLIST_BUDDY" -c 'Print :UUID' "$decoded")"
  [[ "$uuid" =~ ^[A-Fa-f0-9-]+$ ]] || { echo "error: $prefix provisioning profile has an invalid UUID" >&2; exit 1; }
  expiration="$("$PLIST_BUDDY" -x -c 'Print :ExpirationDate' "$decoded" | sed -n 's:.*<date>\(.*\)</date>.*:\1:p' || true)"
  [[ "$expiration" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ && "$expiration" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]] || {
    echo "error: $prefix provisioning profile is expired or has an invalid expiration date" >&2; exit 1;
  }
  team="$("$PLIST_BUDDY" -c 'Print :TeamIdentifier:0' "$decoded")"
  if [[ -z "$TEAM_ID" ]]; then TEAM_ID="$team"; fi
  [[ "$team" == "$TEAM_ID" ]] || { echo "error: $prefix provisioning profile belongs to a different team" >&2; exit 1; }
  [[ "$("$PLIST_BUDDY" -c 'Print :Platform:0' "$decoded")" == "$platform" ]] || { echo "error: $prefix provisioning profile has the wrong platform" >&2; exit 1; }
  identifier="$("$PLIST_BUDDY" -c 'Print :Entitlements:application-identifier' "$decoded" 2>/dev/null || "$PLIST_BUDDY" -c 'Print :Entitlements:com.apple.application-identifier' "$decoded")"
  [[ "$identifier" == "$TEAM_ID.$bundle" ]] || { echo "error: $prefix provisioning profile does not authorize $bundle" >&2; exit 1; }
  development="$("$PLIST_BUDDY" -c 'Print :Entitlements:get-task-allow' "$decoded" 2>/dev/null || true)"
  devices="$("$PLIST_BUDDY" -c 'Print :ProvisionedDevices' "$decoded" 2>/dev/null || true)"
  [[ "$development" != true && -z "$devices" && "$("$PLIST_BUDDY" -c 'Print :ProvisionsAllDevices' "$decoded" 2>/dev/null || true)" != true ]] || { echo "error: $prefix requires an App Store distribution profile" >&2; exit 1; }
  if [[ "$platform" == tvOS ]]; then
    "$PLIST_BUDDY" -c 'Print :Entitlements:com.apple.security.application-groups' "$decoded" | sed 's/^[[:space:]]*//' | grep -Fxq 'group.com.bvolpato.brutv' || {
      echo "error: $prefix provisioning profile must authorize group.com.bvolpato.brutv" >&2; exit 1;
    }
  fi
  cp "$path" "$PROFILE_DIR/$uuid.mobileprovision"
  if [[ -z "${BRUTV_PROVISIONING_PROFILE_DIR:-}" ]]; then
    mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
    cp "$path" "$HOME/Library/MobileDevice/Provisioning Profiles/$uuid.mobileprovision"
  fi
  printf -v "${prefix}_PROFILE_UUID" '%s' "$uuid"
}

import_certificate() {
  local path="$1" password_name="$2" imported pem error_file
  [[ -n "$path" && -f "$path" ]] || { echo "error: missing distribution signing certificate" >&2; exit 1; }
  for imported in ${IMPORTED_CERTIFICATES[@]+"${IMPORTED_CERTIFICATES[@]}"}; do [[ "$imported" != "$path" ]] || return; done
  require_env "$password_name"
  CERTIFICATE_COUNT=$((CERTIFICATE_COUNT + 1))
  pem="$SIGNING_DIR/certificate-$CERTIFICATE_COUNT.pem"
  error_file="$SIGNING_DIR/certificate-$CERTIFICATE_COUNT.error"
  if ! openssl pkcs12 -in "$path" -passin "env:$password_name" -nodes -out "$pem" 2> "$error_file"; then
    if grep -q 'unsupported' "$error_file" && openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
      openssl pkcs12 -legacy -in "$path" -passin "env:$password_name" -nodes -out "$pem"
    else
      cat "$error_file" >&2
      exit 1
    fi
  fi
  security import "$pem" -t agg -f pemseq -k "$KEYCHAIN_PATH" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  IMPORTED_CERTIFICATES+=("$path")
}

if [[ "$SIGNING_MODE" == manual ]]; then
  for platform in "${PLATFORMS[@]}"; do
    case "$platform" in
      ios) read_profile IOS iOS "$BUNDLE_ID" "$IOS_PROFILE_PATH" ;;
      macos) read_profile MACOS OSX "$BUNDLE_ID" "$(input_file MACOS_PROVISIONING_PROFILE .provisionprofile)" ;;
      tvos)
        read_profile TVOS tvOS "$BUNDLE_ID" "$(input_file TVOS_PROVISIONING_PROFILE .mobileprovision)"
        read_profile TVOS_TOPSHELF tvOS "$BUNDLE_ID.TopShelf" "$(input_file TVOS_TOPSHELF_PROVISIONING_PROFILE .mobileprovision)" ;;
    esac
  done
  while IFS= read -r keychain; do
    keychain="${keychain#*\"}"; keychain="${keychain%\"*}"; ORIGINAL_KEYCHAINS+=("$keychain")
  done < <(security list-keychains -d user)
  security create-keychain -p "" "$KEYCHAIN_PATH"
  KEYCHAIN_CREATED=true
  security list-keychains -d user -s "$KEYCHAIN_PATH" ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"}
  security unlock-keychain -p "" "$KEYCHAIN_PATH"
  security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH"
  for platform in "${PLATFORMS[@]}"; do
    if [[ "$platform" == macos ]]; then
      mac_certificate="$(input_file MACOS_APPLICATION_CERTIFICATE .p12)"
      if [[ -n "$mac_certificate" ]]; then
        import_certificate "$mac_certificate" MACOS_APPLICATION_P12_PASSWORD
      elif [[ -n "$CERT_PATH" ]]; then
        import_certificate "$CERT_PATH" IOS_P12_PASSWORD
      fi
      installer_certificate="$(input_file MACOS_INSTALLER_CERTIFICATE .p12)"
      if [[ -n "$installer_certificate" ]]; then import_certificate "$installer_certificate" MACOS_INSTALLER_P12_PASSWORD; fi
    else
      import_certificate "$CERT_PATH" IOS_P12_PASSWORD
    fi
  done
  security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KEYCHAIN_PATH" >/dev/null
else
  TEAM_ID="${TEAM_ID:-83BXSDT7QC}"
fi
identities="$(security find-identity -v)"
for platform in "${PLATFORMS[@]}"; do
  identity="$CODE_SIGN_IDENTITY"
  [[ "$platform" != macos ]] || identity="${MACOS_CODE_SIGN_IDENTITY:-$CODE_SIGN_IDENTITY}"
  if ! grep -F "$identity" <<<"$identities" | grep -Fq "($TEAM_ID)"; then
    echo "error: no valid $identity identity for team $TEAM_ID in the keychain" >&2; exit 1
  fi
done
if [[ " $PLATFORM " == " all " || "$PLATFORM" == macos ]]; then
  if ! grep -E '3rd Party Mac Developer Installer|Mac Installer Distribution' <<<"$identities" | grep -Fq "($TEAM_ID)"; then
    echo "error: a Mac Installer Distribution identity is required for Catalyst export" >&2; exit 1
  fi
fi

validate_profile_identity() {
  local prefix="$1" index=0 certificate hash identity="$CODE_SIGN_IDENTITY"
  [[ "$prefix" != MACOS ]] || identity="${MACOS_CODE_SIGN_IDENTITY:-$CODE_SIGN_IDENTITY}"
  while certificate="$("$PLIST_BUDDY" -x -c "Print :DeveloperCertificates:$index" "$SIGNING_DIR/$prefix.plist" 2>/dev/null)"; do
    certificate="$(sed -n '/<data>/,/<\/data>/p' <<<"$certificate" | sed 's/<\/*data>//g' | tr -d '[:space:]')"
    if base64 --help >/dev/null 2>&1; then
      hash="$(printf '%s' "$certificate" | base64 --decode | openssl dgst -sha1 | awk '{print toupper($NF)}')"
    else
      hash="$(printf '%s' "$certificate" | base64 -D | openssl dgst -sha1 | awk '{print toupper($NF)}')"
    fi
    if grep -F "$hash" <<<"$identities" | grep -F "$identity" | grep -Fq "($TEAM_ID)"; then return; fi
    index=$((index + 1))
  done
  echo "error: $prefix provisioning profile does not authorize an available distribution signing identity" >&2
  exit 1
}
if [[ "$SIGNING_MODE" == manual ]]; then
  for platform in "${PLATFORMS[@]}"; do
    case "$platform" in
      ios) validate_profile_identity IOS ;;
      macos) validate_profile_identity MACOS ;;
      tvos) validate_profile_identity TVOS; validate_profile_identity TVOS_TOPSHELF ;;
    esac
  done
fi

plist_add() { "$PLIST_BUDDY" -c "Add :$2 $3 $4" "$1"; }
write_export_options() {
  local platform="$1" output="$2" upload="$3" uuid
  printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>\n' > "$output"
  plist_add "$output" method string "$EXPORT_METHOD"
  plist_add "$output" signingStyle string "$SIGNING_MODE"
  plist_add "$output" teamID string "$TEAM_ID"
  plist_add "$output" manageAppVersionAndBuildNumber bool false
  [[ "$upload" == false ]] || plist_add "$output" destination string upload
  if [[ "$SIGNING_MODE" == manual ]]; then
    plist_add "$output" provisioningProfiles dict ''
    case "$platform" in
      ios) uuid="$IOS_PROFILE_UUID" ;;
      macos) uuid="$MACOS_PROFILE_UUID" ;;
      tvos) uuid="$TVOS_PROFILE_UUID" ;;
    esac
    plist_add "$output" "provisioningProfiles:$BUNDLE_ID" string "$uuid"
    if [[ "$platform" == tvos ]]; then plist_add "$output" "provisioningProfiles:$BUNDLE_ID.TopShelf" string "$TVOS_TOPSHELF_PROFILE_UUID"; fi
  fi
}

VERSION_ARGS=()
[[ -z "${IOS_BUILD_NUMBER:-}" ]] || VERSION_ARGS+=("CURRENT_PROJECT_VERSION=$IOS_BUILD_NUMBER")
[[ -z "${IOS_MARKETING_VERSION:-}" ]] || VERSION_ARGS+=("MARKETING_VERSION=$IOS_MARKETING_VERSION")
EXPORT_ARGS=()
[[ "$SIGNING_MODE" != automatic ]] || EXPORT_ARGS=(-allowProvisioningUpdates)
cd "$SCRIPT_DIR"

configure_platform() {
  local platform="$1" uuid target setting resolved expected_profile expected_bundle identity="$CODE_SIGN_IDENTITY"
  PLATFORM_DIR="$RUN_DIR/$platform"
  mkdir -p "$PLATFORM_DIR/export"
  SCHEME=BruTV; SDK=iphoneos; DESTINATION='generic/platform=iOS'; TARGET=BruTV
  case "$platform" in
    macos) SDK=macosx; DESTINATION='generic/platform=macOS,variant=Mac Catalyst'; identity="${MACOS_CODE_SIGN_IDENTITY:-$CODE_SIGN_IDENTITY}" ;;
    tvos) SCHEME=BruTV-tvOS; SDK=appletvos; DESTINATION='generic/platform=tvOS'; TARGET=BruTV-tvOS ;;
  esac
  SIGNING_ARGS=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE="$SIGNING_MODE" DEVELOPMENT_TEAM="$TEAM_ID")
  if [[ "$SIGNING_MODE" == automatic ]]; then
    SIGNING_ARGS=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates)
    if [[ "$BUNDLE_ID" != com.bvolpato.brutv ]]; then
      echo "error: custom bundle identifiers require manual signing with matching target profiles" >&2; exit 1
    fi
  else
    case "$platform" in ios) uuid="$IOS_PROFILE_UUID" ;; macos) uuid="$MACOS_PROFILE_UUID" ;; tvos) uuid="$TVOS_PROFILE_UUID" ;; esac
    setting="$SIGNING_DIR/$platform.xcconfig"
    cat > "$setting" <<CONFIG
CODE_SIGNING_ALLOWED = YES
CODE_SIGN_STYLE = Manual
DEVELOPMENT_TEAM = $TEAM_ID
CODE_SIGN_IDENTITY = $identity
BRUTV_PROFILE_BruTV = $uuid
BRUTV_PROFILE_BruTV_tvOS = $uuid
BRUTV_PROFILE_BruTVTopShelf = ${TVOS_TOPSHELF_PROFILE_UUID:-}
BRUTV_BUNDLE_BruTV = $BUNDLE_ID
BRUTV_BUNDLE_BruTV_tvOS = $BUNDLE_ID
BRUTV_BUNDLE_BruTVTopShelf = $BUNDLE_ID.TopShelf
PROVISIONING_PROFILE_SPECIFIER = \$(BRUTV_PROFILE_\$(TARGET_NAME:c99extidentifier))
PRODUCT_BUNDLE_IDENTIFIER = \$(BRUTV_BUNDLE_\$(TARGET_NAME:c99extidentifier))
CONFIG
    SIGNING_ARGS=(-xcconfig "$setting")
    # Check actual Xcode expansion before an archive can use the wrong profile.
    TARGETS=("$TARGET")
    [[ "$platform" != tvos ]] || TARGETS+=(BruTVTopShelf)
    for target in "${TARGETS[@]}"; do
      expected_profile="$uuid"; expected_bundle="$BUNDLE_ID"
      if [[ "$target" == BruTVTopShelf ]]; then expected_profile="$TVOS_TOPSHELF_PROFILE_UUID"; expected_bundle="$BUNDLE_ID.TopShelf"; fi
      resolved="$(xcodebuild -showBuildSettings -project BruTV.xcodeproj -target "$target" -configuration Release -sdk "$SDK" -xcconfig "$setting")"
      if [[ "$(awk '$1 == "PROVISIONING_PROFILE_SPECIFIER" && $2 == "=" {print $3}' <<<"$resolved")" != "$expected_profile" ||
            "$(awk '$1 == "PRODUCT_BUNDLE_IDENTIFIER" && $2 == "=" {print $3}' <<<"$resolved")" != "$expected_bundle" ]]; then
        echo "error: Xcode did not resolve the expected signing profile and bundle identifier for $target" >&2; exit 1
      fi
    done
  fi
  write_export_options "$platform" "$PLATFORM_DIR/ExportOptions.plist" false
  write_export_options "$platform" "$PLATFORM_DIR/ExportOptions-Upload.plist" true
}

# Preflight every requested platform before building any of them.
for platform in "${PLATFORMS[@]}"; do configure_platform "$platform"; done
if [[ "$PREFLIGHT" == true ]]; then echo "All requested Apple signing preflights passed. No builds or uploads performed."; exit 0; fi

for platform in "${PLATFORMS[@]}"; do
  configure_platform "$platform"
  if [[ "$platform" == ios ]]; then
    icon="$SCRIPT_DIR/BruTV/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png"
    [[ -f "$icon" ]] || { echo "error: missing App Store icon" >&2; exit 1; }
    icon_info="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$icon")"
    if ! grep -q 'pixelWidth: 1024' <<<"$icon_info" || ! grep -q 'pixelHeight: 1024' <<<"$icon_info" || grep -q 'hasAlpha: yes' <<<"$icon_info"; then
      echo "error: App Store icon must be 1024x1024 with no alpha" >&2; exit 1
    fi
  fi
  if [[ "$SKIP_SIM_BUILD" == false && "$platform" != macos ]]; then
    simulator="${IOS_SIM_DESTINATION:-platform=iOS Simulator,name=iPhone 17e}"
    simulator_sdk=iphonesimulator
    if [[ "$platform" == tvos ]]; then
      simulator="${TVOS_SIM_DESTINATION:-generic/platform=tvOS Simulator}"
      simulator_sdk=appletvsimulator
    fi
    xcodebuild build -project BruTV.xcodeproj -scheme "$SCHEME" -sdk "$simulator_sdk" -configuration Release -destination "$simulator" CODE_SIGNING_ALLOWED=NO ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"}
  fi
  xcodebuild archive -project BruTV.xcodeproj -scheme "$SCHEME" -sdk "$SDK" -configuration Release -destination "$DESTINATION" -archivePath "$PLATFORM_DIR/BruTV.xcarchive" "${SIGNING_ARGS[@]}" ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"}
  xcodebuild -exportArchive -archivePath "$PLATFORM_DIR/BruTV.xcarchive" -exportOptionsPlist "$PLATFORM_DIR/ExportOptions.plist" -exportPath "$PLATFORM_DIR/export" ${EXPORT_ARGS[@]+"${EXPORT_ARGS[@]}"}
  extension=ipa; [[ "$platform" != macos ]] || extension=pkg
  package="$(find "$PLATFORM_DIR/export" -maxdepth 1 -name "*.$extension" -type f | head -n 1)"
  [[ -n "$package" && -s "$package" ]] || { echo "error: $platform export did not produce a $extension package" >&2; exit 1; }
  echo "$platform package: $package"
done

if [[ "$UPLOAD" == true ]]; then
  for platform in "${PLATFORMS[@]}"; do
    xcodebuild -exportArchive -archivePath "$RUN_DIR/$platform/BruTV.xcarchive" -exportOptionsPlist "$RUN_DIR/$platform/ExportOptions-Upload.plist" -exportPath "$RUN_DIR/$platform/upload" ${EXPORT_ARGS[@]+"${EXPORT_ARGS[@]}"}
  done
  echo "Upload commands completed. Verify App Store Connect processing before release."
fi
echo "Requested Apple packages exported to $RUN_DIR. Previous release artifacts were preserved."

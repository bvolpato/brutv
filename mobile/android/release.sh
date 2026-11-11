#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

play_bundle=false
gradle_args=()
for argument in "$@"; do
    case "$argument" in
        --play-bundle) play_bundle=true ;;
        -h|--help)
            echo "Usage: ./release.sh [--play-bundle] [Gradle options...]"
            echo "  --play-bundle  Also produce a separate API 24 Google Play App Bundle."
            exit 0
            ;;
        *) gradle_args+=("$argument") ;;
    esac
done

signing_properties="${BRUTV_ANDROID_SIGNING_PROPERTIES:-${XDG_CONFIG_HOME:-$HOME/.config}/brutv/android/keystore.properties}"
if [[ ! -f "$signing_properties" ]]; then
    echo "Android release signing is not configured: $signing_properties is missing." >&2
    echo "Create the production keystore and local keystore.properties before building." >&2
    exit 1
fi

for property in storeFile storePassword keyAlias keyPassword; do
    if ! awk -F= -v key="$property" '$1 == key && length($2) > 0 { found = 1 } END { exit !found }' "$signing_properties"; then
        echo "Android release signing is incomplete: $property is missing from $signing_properties." >&2
        exit 1
    fi
done

keystore="$(sed -n 's/^storeFile=//p' "$signing_properties" | sed -n '1p')"
if [[ -z "$keystore" || ! -f "$keystore" ]]; then
    echo "Android release signing keystore is missing or unreadable." >&2
    exit 1
fi

export BRUTV_ANDROID_SIGNING_PROPERTIES="$signing_properties"
./gradlew :app:assembleRelease :app:bundleRelease "${gradle_args[@]}"

apk="app/build/outputs/apk/release/app-release.apk"
bundle="app/build/outputs/bundle/release/app-release.aab"
metadata="app/build/outputs/apk/release/output-metadata.json"
if [[ ! -f "$apk" || ! -f "$bundle" || ! -f "$metadata" ]]; then
    echo "Android release build did not produce both APK and App Bundle outputs." >&2
    exit 1
fi

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -f local.properties ]]; then
    sdk_root="$(sed -n 's/^sdk.dir=//p' local.properties | sed -n '1p')"
fi
apksigner=""
for candidate in "$sdk_root"/build-tools/*/apksigner; do
    [[ -f "$candidate" ]] && apksigner="$candidate"
done
if [[ -z "$apksigner" ]]; then
    echo "Could not find apksigner in the configured Android SDK." >&2
    exit 1
fi
apk_verification="$(bash "$apksigner" verify --print-certs "$apk" 2>&1)" || {
    printf '%s\n' "$apk_verification" >&2
    echo "Release APK signature verification failed." >&2
    exit 1
}
apk_certificate="$(printf '%s\n' "$apk_verification" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | sed -n '1p' | tr -d ':[:space:]' | tr '[:upper:]' '[:lower:]')"
if [[ -z "$apk_certificate" ]]; then
    echo "Release APK signer certificate could not be read." >&2
    exit 1
fi

bundle_verification="$(jarsigner -verify "$bundle" 2>&1)" || {
    printf '%s\n' "$bundle_verification" >&2
    echo "Release App Bundle signature verification failed." >&2
    exit 1
}
bundle_certificate_output="$(keytool -printcert -jarfile "$bundle" 2>&1)" || {
    printf '%s\n' "$bundle_certificate_output" >&2
    echo "Release App Bundle signer certificate could not be read." >&2
    exit 1
}
bundle_certificate="$(printf '%s\n' "$bundle_certificate_output" | sed -n 's/^[[:space:]]*SHA256: //p' | sed -n '1p' | tr -d ':[:space:]' | tr '[:upper:]' '[:lower:]')"
if [[ -z "$bundle_certificate" || "$apk_certificate" != "$bundle_certificate" ]]; then
    echo "Release APK and App Bundle do not have the same signing certificate." >&2
    exit 1
fi

version_name="$(sed -n 's/.*"versionName": "\([^"]*\)".*/\1/p' "$metadata" | sed -n '1p')"
version_code="$(sed -n 's/.*"versionCode": \([0-9][0-9]*\).*/\1/p' "$metadata" | sed -n '1p')"
if [[ -z "$version_name" || -z "$version_code" ]]; then
    echo "Could not read release version from $metadata." >&2
    exit 1
fi

distribution_dir="build/distributions"
mkdir -p "$distribution_dir"
final_apk="$distribution_dir/BruTV-android-${version_name}-${version_code}.apk"
final_bundle="$distribution_dir/BruTV-android-${version_name}-${version_code}.aab"
cp "$apk" "$final_apk"
cp "$bundle" "$final_bundle"

printf 'Signed APK: %s\n' "$final_apk"
printf 'Signed AAB: %s\n' "$final_bundle"

if [[ "$play_bundle" = true ]]; then
    ./gradlew :app:bundleRelease -PbrutvMinSdk=24 "${gradle_args[@]}"

    play_manifest="app/build/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml"
    if [[ ! -f "$play_manifest" ]] || ! grep -Fq 'android:minSdkVersion="24"' "$play_manifest"; then
        echo "Google Play App Bundle manifest does not declare the required API 24 minimum." >&2
        exit 1
    fi

    play_bundle_verification="$(jarsigner -verify "$bundle" 2>&1)" || {
        printf '%s\n' "$play_bundle_verification" >&2
        echo "Google Play App Bundle signature verification failed." >&2
        exit 1
    }
    play_certificate_output="$(keytool -printcert -jarfile "$bundle" 2>&1)" || {
        printf '%s\n' "$play_certificate_output" >&2
        echo "Google Play App Bundle signer certificate could not be read." >&2
        exit 1
    }
    play_certificate="$(printf '%s\n' "$play_certificate_output" | sed -n 's/^[[:space:]]*SHA256: //p' | sed -n '1p' | tr -d ':[:space:]' | tr '[:upper:]' '[:lower:]')"
    if [[ -z "$play_certificate" || "$apk_certificate" != "$play_certificate" ]]; then
        echo "Google Play App Bundle and direct APK do not have the same signing certificate." >&2
        exit 1
    fi

    final_play_bundle="$distribution_dir/BruTV-android-play-${version_name}-${version_code}.aab"
    cp "$bundle" "$final_play_bundle"
    printf 'Signed Google Play App Bundle: %s\n' "$final_play_bundle"

    ./gradlew :app:bundleRelease "${gradle_args[@]}"
    standard_manifest="app/build/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml"
    if [[ ! -f "$standard_manifest" ]] || ! grep -Fq 'android:minSdkVersion="23"' "$standard_manifest"; then
        echo "Standard App Bundle manifest was not restored to API 23." >&2
        exit 1
    fi
fi

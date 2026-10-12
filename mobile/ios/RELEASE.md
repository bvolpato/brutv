# iOS Release Guide - BruTV

This guide documents the procedures for building, testing, taking screenshots, and releasing BruTV for iOS and iPadOS.

---

## Prerequisites

- **macOS** with **Xcode 16+** (or Xcode 27+).
- **Apple Developer Account** with access to Team ID `83BXSDT7QC` (Bruno Candido Volpato da Cunha).
- Command line utilities: `xcodebuild`, `xcrun`, `sips`, `security`.

---

## 1. Local Simulator Build

To verify compilation and generate a local simulator `.app`:

```bash
./mobile/ios/BruTV/build.sh
```

Override simulator destination if desired:

```bash
IOS_SIM_DESTINATION="platform=iOS Simulator,name=iPad Pro 13-inch (M5)" ./mobile/ios/BruTV/build.sh
```

---

## 2. Running Automated Tests

Run the full unit and UI test suite:

```bash
./mobile/ios/BruTV/test.sh
```

---

## 3. Capturing App Store Screenshots

BruTV includes an automated capture script that boots the iPhone and iPad simulators, exercises the routes, and formats the output into required App Store Connect dimensions:

```bash
./mobile/ios/BruTV/capture-screenshots.sh
```

Generated directories:
- `screenshots/6.7-inch/` (1290 x 2796)
- `screenshots/6.5-inch/` (1242 x 2688)
- `screenshots/ipad-13-inch/` (2048 x 2732)

---

## 4. Building the Signed App Store IPA

Set up the required release environment variables:

```bash
export IOS_TEAM_ID="83BXSDT7QC"
export IOS_PROFILE_NAME="BruTV AppStore Distribution"
export IOS_P12_PASSWORD="<password>"

# Provide signing assets either as base64:
export IOS_CERTIFICATE_BASE64="$(base64 -i path/to/distribution.p12)"
export IOS_PROVISIONING_PROFILE_BASE64="$(base64 -i path/to/profile.mobileprovision)"

# Or as file paths:
export IOS_CERTIFICATE_PATH="$PWD/signing/ios_distribution.p12"
export IOS_PROVISIONING_PROFILE_PATH="$PWD/signing/BruTV_App_Store_Distribution.mobileprovision"
```

Execute release:

```bash
./mobile/ios/BruTV/release.sh
```

The script archives the project, validates entitlements, codesigns with Apple Distribution identity, and exports the signed `.ipa` under `mobile/ios/BruTV/build/release/export/`.

---

## 5. Upload to TestFlight / App Store

Upload the IPA using `xcrun altool` or `xcrun notarytool`:

```bash
xcrun altool --upload-app -f "mobile/ios/BruTV/build/release/export/BruTV.ipa" -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

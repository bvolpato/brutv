# iOS Signing for BruTV

Signing material is intentionally not committed to version control.

## Bundle Identifier & Team
- **Bundle ID:** `com.bvolpato.brutv` (override via `IOS_BUNDLE_ID`)
- **Apple Developer Team ID:** `83BXSDT7QC` (Bruno Candido Volpato da Cunha)

## Required Release Environment

```bash
export IOS_TEAM_ID="83BXSDT7QC"
export IOS_PROFILE_NAME="<app-store-profile-name>"
export IOS_P12_PASSWORD="<p12-password>"
```

Provide signing files either as base64 values:

```bash
export IOS_CERTIFICATE_BASE64="$(base64 -i ios_distribution.p12)"
export IOS_PROVISIONING_PROFILE_BASE64="$(base64 -i BruTV_App_Store_Distribution.mobileprovision)"
```

or as local file paths:

```bash
export IOS_CERTIFICATE_PATH="$PWD/signing/ios_distribution.p12"
export IOS_PROVISIONING_PROFILE_PATH="$PWD/signing/BruTV_App_Store_Distribution.mobileprovision"
```

Then run:

```bash
./mobile/ios/BruTV/release.sh
```

The script creates a temporary isolated keychain, archives the release target, exports an App Store IPA, and outputs the resulting `.ipa` path.

# iOS Signing for BruTV

Git ignores this folder's signing material, including private keys, certificates, API keys, and provisioning profiles. Only this README is tracked.

## Bundle Identifier and Team
- **Bundle ID:** `com.bvolpato.brutv` (override with `IOS_BUNDLE_ID`)
- **Apple Developer Team ID:** `83BXSDT7QC` (Bruno Candido Volpato da Cunha)

## Local Release

1. Put these two files in this folder:
   - The Apple Distribution certificate, exported as a `.p12` file.
   - The App Store provisioning profile for `com.bvolpato.brutv`, as a `.mobileprovision` file.
2. Run the release script:

```bash
IOS_P12_PASSWORD='<p12-password>' ./mobile/ios/BruTV/release.sh --skip-simulator-build
```

The script reads the profile name and the team ID from the profile. To override them, set `IOS_PROFILE_NAME` and `IOS_TEAM_ID`.

On Linux, select iOS explicitly:

```bash
IOS_P12_PASSWORD='<p12-password>' ./mobile/ios/BruTV/release.sh --platform ios
```

The Linux helper discovers one `.p12` and one `.mobileprovision` in this folder. `IOS_CERTIFICATE_PATH` and `IOS_PROVISIONING_PROFILE_PATH` select files elsewhere. It verifies Apple's profile signature, team, certificate, entitlements, and the resulting IPA. It uses xtool and a private signing tool installation. The [release guide](../../RELEASE.md#linux-builds-and-delivery) covers SDK setup, Mac and tvOS signing, and API upload configuration.

## CI Release

Provide the files as base64 values:

```bash
export IOS_CERTIFICATE_BASE64="$(base64 -i ios_distribution.p12)"
export IOS_PROVISIONING_PROFILE_BASE64="$(base64 -i BruTV_App_Store_Distribution.mobileprovision)"
export IOS_P12_PASSWORD="<p12-password>"
./mobile/ios/BruTV/release.sh
```

On macOS, the script creates a temporary keychain and archives with Xcode. On Linux, add `--platform ios` to build and sign the IPA with xtool. Add `--upload` and the App Store Connect API key configuration from the release guide to deliver it and wait for processing.

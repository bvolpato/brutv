# iOS Signing for BruTV

Git does not track signing material. The `.gitignore` file excludes `*.p12` and `*.mobileprovision`.

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

## CI Release

Provide the files as base64 values:

```bash
export IOS_CERTIFICATE_BASE64="$(base64 -i ios_distribution.p12)"
export IOS_PROVISIONING_PROFILE_BASE64="$(base64 -i BruTV_App_Store_Distribution.mobileprovision)"
export IOS_P12_PASSWORD="<p12-password>"
./mobile/ios/BruTV/release.sh
```

The script creates a temporary keychain, archives the Release configuration, exports an App Store IPA, and prints the `.ipa` path.

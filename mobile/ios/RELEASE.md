# iOS Release Guide - BruTV

This guide documents the procedures for building, testing, taking screenshots, and releasing BruTV for iOS and iPadOS.

## Product and release decisions

Decisions confirmed on October 12, 2026:

- BruTV will be free, with the positioning **"IPTV that just works."**
- The intended release supports iPhone, iPad, and Mac through Mac Catalyst.
- The intended release will not bundle provider credentials, demo accounts, or reviewer streams. The current prototype still contains legacy demo code; it was left unchanged at the owner's request and must be removed before release.
- `.m3u` playlist import from a file or URL and a catalog of public streams are planned. Neither feature nor a generated public playlist has been implemented. App changes are paused at the owner's request.
- Any future public catalog must retain source attribution and distinguish accessible streams from permission to distribute or display them. Content-rights and age-rating declarations remain pending.

The Apple Developer identifier is `com.bvolpato.brutv` under team `83BXSDT7QC`. App Store Connect record `6821989154` has iOS and macOS `1.0.0` drafts, English (U.S.) metadata, Entertainment / Utilities categories, and manual release selected on both platforms. The approved **Data Not Collected** privacy response is published. Free pricing is the product decision; the App Store price schedule has not yet been configured.

- App record: https://appstoreconnect.apple.com/apps/6821989154/distribution/info
- Support and marketing: https://brunovolpato.com/brutv/
- Privacy policy: https://brunovolpato.com/brutv/privacy/

The public support and privacy pages are deployed. Native compilation, tests, signed archives, real device screenshots, and upload still require a Mac. Verify the Mac sandbox, outgoing network access, icon, and shared bundle identifier. The existing release script below exports iOS only; archive Mac Catalyst separately through Xcode Organizer. Reviewer contact and access details remain pending.

Before submission, install a stable Xcode version that meets Apple's current SDK requirements. As of this decision date, uploads require Xcode 26 or later with the iOS / iPadOS 26 SDK: https://developer.apple.com/news/upcoming-requirements/?id=04282026a

---

## Prerequisites

- **macOS** with a stable **Xcode 26+** version and the required platform SDKs.
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

The capture script runs the `testCaptureStoreScreenshots` UI test on an iPhone 18 Pro Max and an iPad Pro 13-inch (M5) simulator. The test signs in with the public iptv-org playlist, so the images contain no private account data. It sets the status bar to 9:41 with full battery.

```bash
./mobile/ios/BruTV/capture-screenshots.sh
```

Output, at native resolution with no resizing:
- `screenshots/iphone-6.9-inch/` (1320 x 2868)
- `screenshots/ipad-13-inch/` (2064 x 2752)

Each folder has `01_login`, `02_channels`, `03_player`, `04_guide`, and `05_settings`. To change the category chip or the channel that plays, set `BRUTV_SCREENSHOT_CATEGORY` or `BRUTV_SCREENSHOT_CHANNEL`.

---

## 4. Building the Signed App Store IPA

Put the distribution certificate and the App Store provisioning profile in `mobile/ios/BruTV/signing/`. Git ignores `.p12` and `.mobileprovision` files. The script reads the profile name and team ID from the profile.

```bash
IOS_P12_PASSWORD='<password>' ./mobile/ios/BruTV/release.sh --skip-simulator-build
```

In CI, set `IOS_CERTIFICATE_BASE64` and `IOS_PROVISIONING_PROFILE_BASE64` instead. `IOS_TEAM_ID`, `IOS_PROFILE_NAME`, `IOS_BUILD_NUMBER`, and `IOS_MARKETING_VERSION` override the defaults.

The script archives the project, signs with the Apple Distribution identity in a temporary keychain, and exports the `.ipa` to `mobile/ios/BruTV/build/release/export/`.

Release builds contain no test account. The demo credentials are inside `#if DEBUG` blocks.

---

## 5. Upload to TestFlight / App Store

Use one of these options:
- Transporter app: drag `BruTV.ipa` into the window, then click Deliver.
- Command line with an App Store Connect API key:

```bash
xcrun altool --upload-app -f "mobile/ios/BruTV/build/release/export/BruTV.ipa" -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

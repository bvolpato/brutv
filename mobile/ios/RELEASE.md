# iOS Release Guide - BruTV

This guide documents the procedures for building, testing, taking screenshots, and releasing BruTV for iOS and iPadOS.

## Product and release decisions

Decisions confirmed on October 12, 2026:

- BruTV will be free, with the positioning **"IPTV that just works."**
- The intended release supports iPhone, iPad, and Mac through Mac Catalyst.
- The intended release will not bundle provider credentials, demo accounts, or reviewer streams. Status: the demo account code is inside `#if DEBUG` blocks, so Release builds do not contain it. A check of the Release binary found no server URL and no demo symbols. The App Review notes point to the public iptv-org playlist. The app does not bundle it.
- `.m3u` playlist import from a URL is implemented. Import from a file and a catalog of public streams are still planned. No generated public playlist exists.
- Any future public catalog must retain source attribution and distinguish accessible streams from permission to distribute or display them. Content-rights and age-rating declarations remain pending.

The Apple Developer identifier is `com.bvolpato.brutv` under team `83BXSDT7QC`. App Store Connect record `6821989154` has iOS and macOS `1.0.0` drafts, English (U.S.) metadata, Entertainment / Utilities categories, and manual release selected on both platforms. The approved **Data Not Collected** privacy response is published. Free pricing is the product decision; the App Store price schedule has not yet been configured.

- App record: https://appstoreconnect.apple.com/apps/6821989154/distribution/info
- Support and marketing: https://brunovolpato.com/brutv/
- Privacy policy: https://brunovolpato.com/brutv/privacy/

The public support and privacy pages are deployed. Full app compilation and tests, signed archives, real device screenshots, and upload still require a Mac. The portable Swift core suite also runs on Linux. Verify the Mac sandbox, outgoing network access, icon, and shared bundle identifier. The existing release script below exports iOS only; archive Mac Catalyst separately through Xcode Organizer. Reviewer contact and access details remain pending.

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

Run the full unit and UI test suite on a Mac with Xcode:

```bash
./mobile/ios/BruTV/test.sh
```

If the default simulator is unavailable, list installed devices and select an available simulator UDID:

```bash
xcrun simctl list devices available
IOS_SIM_DESTINATION="platform=iOS Simulator,id=<available-UDID>" ./test.sh
```

Run the portable suite on Linux or macOS:

```bash
./test.sh --core
```

This command uses local Swift when available, otherwise a pinned official Swift Docker image. Docker tests run without network access and use fixture responses. The package compiles the production source parser, Xtream client, source identity/library helpers, and playback policy. It excludes AVFoundation, Combine stores, and SwiftUI.

The October 12 Android follow-up reproduced six source regressions against the original iOS source and fixed them. All 37 portable tests pass in debug and release configurations; every Apple Swift source and test file also passes syntax parsing. New Xcode tests cover cancelled or overlapping sign-ins, source-specific favorites and history, pausing during connection, native transport controls, and resuming a pending movie seek. Syntax parsing does not type-check Apple framework APIs. Those native tests, the full app build, Picture in Picture controls, VOD recovery, and real device playback remain unverified until run on a Mac.

The Apple buffer preferences remain 1.5, 4, and 10 seconds. They request buffering ahead of the playhead through AVPlayer's [preferredForwardBufferDuration](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredforwardbufferduration). They do not force Android-style live-edge offsets.

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

The script has two signing modes.

**Automatic (default on this Mac).** Use it when `signing/` has no signing files. You need two things:

- The Apple ID is signed in to Xcode (Settings > Accounts).
- The login keychain has an Apple Distribution certificate for team `83BXSDT7QC`. To create one, go to Accounts > Manage Certificates > + > Apple Distribution.

Xcode creates the App Store profile.

```bash
./mobile/ios/BruTV/release.sh --skip-simulator-build
```

**Manual.** Put the distribution certificate (`.p12`) and the App Store provisioning profile in `mobile/ios/BruTV/signing/`. Git ignores `.p12` and `.mobileprovision` files. The script reads the profile name and team ID from the profile.

```bash
IOS_P12_PASSWORD='<password>' ./mobile/ios/BruTV/release.sh --skip-simulator-build
```

In CI, set `IOS_CERTIFICATE_BASE64` and `IOS_PROVISIONING_PROFILE_BASE64` instead. `IOS_SIGNING`, `IOS_TEAM_ID`, `IOS_PROFILE_NAME`, `IOS_BUILD_NUMBER`, and `IOS_MARKETING_VERSION` override the defaults.

The script exports the `.ipa` to `mobile/ios/BruTV/build/release/export/`. In manual mode, it signs in a temporary keychain.

If the export fails with `Copy failed` and an `rsync` error, a Homebrew `rsync` is first on `PATH`. The script puts `/usr/bin` first to avoid this.

Release builds contain no test account. The demo credentials are inside `#if DEBUG` blocks.

`tools/make-app-icon.swift` draws the app icon and writes every size in `AppIcon.appiconset`. App Store Connect rejects the upload with error 91111 if `AppIcon1024.png` is not exactly 1024 x 1024 or has an alpha channel. `release.sh` checks this before it archives. To regenerate the icons, run `swift tools/make-app-icon.swift` from the repo root.

Each upload needs a new build number. Raise `CURRENT_PROJECT_VERSION` in the project, or set `IOS_BUILD_NUMBER`.

---

## 5. Upload to TestFlight / App Store

Use one of these options:
- Transporter app: drag `BruTV.ipa` into the window, then click Deliver.
- Command line with an App Store Connect API key:

```bash
xcrun altool --upload-app -f "mobile/ios/BruTV/build/release/export/BruTV.ipa" -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

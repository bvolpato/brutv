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

The public support and privacy pages are deployed. On macOS, the release script builds iOS, Mac Catalyst, and tvOS through Xcode. On Linux, it dispatches to the xtool build, distribution signing, and App Store Connect API upload helpers described below. Apple simulators and screenshot capture still require macOS. The portable Swift core suite also runs on Linux. Verify the Mac sandbox, outgoing network access, icon, and shared bundle identifier. App Store Connect review information includes a public playlist test route and the Catalyst loopback server entitlement explanation in [the reviewer notes](STORE_LISTING.md#additional-macos-review-notes).

Before submission, install a stable Xcode version that meets Apple's current SDK requirements. As of this decision date, uploads require Xcode 26 or later with the iOS / iPadOS 26 SDK: https://developer.apple.com/news/upcoming-requirements/?id=04282026a

---

## Live pause and rewind validation

Live playback now records clear, muxed MPEG-TS HLS into a per-channel temporary ring independently of AVPlayer. Pause stops presentation while capture continues while the app is active. The retained window is at most 10 minutes, with a **256 MiB total on-disk cap**. Recently advertised HLS segments remain leased for in-flight playback and count against the same cap; half the budget is reserved for those leases, so high-bitrate rewind windows can be shorter. Manifests are capped at 1 MiB and segments at 32 MiB during receipt. Parsed playlists and retained session files are limited to 2,000 segments, with a minimum segment duration of 0.25 seconds. Open HTTP readers hold counted file leases until they close. Changing channels, stopping playback, or logging out removes the session; stale owned sessions are removed on next startup.

The player shows retained time and temporary bytes, rewind/forward controls, and a seek slider. Go Live appears after pause or rewind moves playback behind the normal live point. It also appears when ordinary playback falls more than 15 seconds behind. It seeks to a three-segment holdback before resuming. When paused content ages out, playback clamps to the oldest retained point. Missing capture intervals are marked as discontinuities with a visible notice.

Encrypted/DRM HLS, external audio/subtitle renditions, fragmented MP4 initialization maps, byte-range segments, and unsupported playlist types fall back to direct playback with a visible rewind-unavailable reason. Supported master playlists use one muxed variant, preferring the highest bitrate at or below 8 Mbps. This initial recorder does not provide adaptive variant switching. A native decoder or unsupported-format failure in the recorded variant triggers one attempt to play the original provider URL directly, with a visible rewind-unavailable reason. The recorder closes before direct playback starts, and playback intent is preserved.

On iPhone and iPad, paused capture is **not guaranteed when the app is backgrounded or the device is locked**. The operating system can suspend the app. Active background audio playback uses the existing audio mode. Capture resumes when the app becomes active; content missed during suspension cannot be recovered from an expired upstream window. Mac Catalyst can capture while its process remains active, excluding sleep or termination. The Catalyst-only entitlement file enables sandbox network client/server access for the loopback server; iOS uses its original entitlements.

Before release, use a signed native build to run the controlled moving HLS fixture described in the repository README. Confirm on iPhone, iPad, and Mac Catalyst: pause for longer than the provider's playlist window; manually retry the player while delayed and verify the playhead stays on the same recorded content; verify saved bytes increase while the picture remains paused; resume and rewind into content already expired upstream; seek forward and use Go Live; run past the retention and storage caps; change channels and log out; background/lock and resume; reject unsupported streams without losing ordinary playback. Confirm the Catalyst network entitlements with the signed app. Compilation and portable Swift tests do not validate AVPlayer or Network.framework runtime behavior.

## Linux builds and delivery

The Linux path uses the BruTV xtool fork's platform support. It builds the full app from the same Swift sources as the Xcode application target, checks source-list parity, and reads the bundle identifier and version from the Xcode Release settings. It compiles iOS/Catalyst icon assets with pinned AssetKit and creates a universal Catalyst executable. The default portable `Package.swift` behavior remains unchanged.

The tested fork is [bvolpato/xtool at `df68ba5`](https://github.com/bvolpato/xtool/commit/df68ba5a5b290c57146b970534ce55dc5b9a7240), on `codex/linux-apple-platforms`. [Upstream PR #362](https://github.com/xtool-org/xtool/pull/362) contains the platform changes. Until they are merged, point `XTOOL_SOURCE_DIR` at that checkout rather than upstream `main`.

**Release parity is not yet established.** On October 16, the complete Linux release command built iOS version 1.0.1 (16) and its matching dSYM with the real SDK 27.1, signed the IPA using the team's Apple Distribution identity and a BruTV App Store profile, and verified the package. Both Catalyst architectures also compiled and linked on Linux. Mac package signing and App Store Connect processing remain unverified. tvOS currently stops with an explicit error because AssetKit cannot compile `TVAppIcon.brandassets` layered icons. The default all-platform release stops at preflight rather than dropping tvOS or uploading a partial set.

Install the Apple SDK from an Xcode archive downloaded through your Apple Developer account, then install signing tools privately in the ignored build directory:

```bash
export XTOOL_SOURCE_DIR=/path/to/the/brutv-xtool-fork
./mobile/ios/BruTV/setup-linux.sh /path/to/Xcode.xip
./mobile/ios/BruTV/setup-linux.sh --signing-tools
./mobile/ios/BruTV/setup-linux.sh --catalyst-linker
```

The repository provides Docker-backed Swift 6.4 and xtool wrappers when native tools are unavailable. SDKs and caches stay in `mobile/ios/BruTV/build/linux-tools/`. `SWIFT_BINARY`, `XTOOL_BINARY`, and `XTOOL_SOURCE_DIR` select existing tools or a local fork checkout. Release builds require the fork's platform support and accurate SDK metadata. `BRUTV_BUILD_JOBS` limits toolchain concurrency (default 4). Release builds also produce `BruTV.app.dSYM` beside the unsigned app for crash symbolication.

The Catalyst linker installer extracts only `lld` and its `ld64.lld` alias from the official LLVM 23.1.3 release after checking its pinned SHA-256. This includes [LLVM's fix for arm64e SDK reexports](https://github.com/llvm/llvm-project/pull/193065), which the current Apple SDK needs. The wrappers select the private linker automatically. `XTOOL_LD64_LLD` selects another executable; `BRUTV_LLVM_TOOLS_DIR` changes its installation directory. `BRUTV_LLVM_ARCHIVE` can reuse a downloaded official archive, with the same checksum check.

```bash
# Unsigned device apps, suitable for compilation checks.
./mobile/ios/BruTV/build.sh ios
./mobile/ios/BruTV/build.sh macos

# Compile resources and stage sources without an Apple SDK.
./mobile/ios/BruTV/linux-build.sh --platform ios --prepare-only

# Validate credentials, tools, and all requested SDKs before building.
./mobile/ios/BruTV/release.sh --platform ios --preflight --upload

# Build, distribution-sign, and upload one explicitly selected platform.
IOS_BUILD_NUMBER=16 ./mobile/ios/BruTV/release.sh --platform ios --upload
```

`release.sh` defaults to `--platform all` (iOS, Catalyst, tvOS). Select `ios` or `macos` explicitly for a subset. Linux never invokes a simulator; `--skip-simulator-build` is accepted for compatibility. Every requested package is built, signed, and checked before the first upload. If Apple rejects a later upload, previous uploads cannot be rolled back automatically. A successful upload requires the Build Upload API to complete and the linked build to become `VALID`. It does not submit the app for review or publish it.

Distribution credentials are required independently of xtool's on-device development authentication:

| Platform | Required configuration |
| --- | --- |
| iOS/iPadOS | `IOS_CERTIFICATE_PATH`, `IOS_P12_PASSWORD`, `IOS_PROVISIONING_PROFILE_PATH` |
| tvOS | Shared distribution certificate plus `TVOS_PROVISIONING_PROFILE_PATH` and `TVOS_TOPSHELF_PROVISIONING_PROFILE_PATH`; both profiles must authorize `group.com.bvolpato.brutv` |
| Mac Catalyst | `MACOS_APPLICATION_CERTIFICATE_PATH`, `MACOS_APPLICATION_P12_PASSWORD`, `MACOS_INSTALLER_CERTIFICATE_PATH`, `MACOS_INSTALLER_P12_PASSWORD`, `MACOS_PROVISIONING_PROFILE_PATH` |
| App Store Connect upload | `IOS_ASC_KEY_ID`, `IOS_ASC_ISSUER_ID`, `IOS_ASC_PRIVATE_KEY_PATH` (unencrypted P-256 `.p8` key); `ASC_*` aliases are accepted |

Certificate and provisioning profile variables also accept `_BASE64` in place of `_PATH`. Do not put passwords or key contents in command arguments. iOS/tvOS use the private zsign installation; Mac Catalyst uses rcodesign and genuine BOM/CPIO/XAR installer tools. The helpers verify distribution profiles, certificate trust, entitlements, executable signatures, sealed resources, and installer checksums. They preserve an existing output if signing fails. `upload-build.py --validate-only` validates package structure offline; cryptographic verification belongs to the signing helper.

## macOS prerequisites

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

The October 12 Android follow-up reproduced six source regressions against the original iOS source and fixed them. All 37 portable tests passed in debug and release configurations; every Apple Swift source and test file also passed syntax parsing. New Xcode tests cover cancelled or overlapping sign-ins, source-specific favorites and history, pausing during connection, native transport controls, and resuming a pending movie seek. The October 16 Linux iOS Release build compiles all application sources against the actual Apple SDK. Native tests, Picture in Picture controls, VOD recovery, and real device playback still need runtime validation; simulator and Xcode UI tests require macOS.

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

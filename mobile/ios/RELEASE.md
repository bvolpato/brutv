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

Build and test with [Xcode 27.2 and its iOS 27.2 SDK](https://developer.apple.com/news/releases/?id=10292026a), the current stable toolchain. Build and release preflight checks reject older SDKs. This updates the build SDK without changing the minimum supported iOS version, which remains 17. Xcode 27.3 is currently beta and is not the CI default.

---

## Live pause and rewind validation

Live playback now records clear, muxed MPEG-TS HLS into a per-channel temporary ring independently of AVPlayer. Pause stops presentation while capture continues while the app is active. The retained window is at most 10 minutes, with a **256 MiB total on-disk cap**. Recently advertised HLS segments remain leased for in-flight playback and count against the same cap; half the budget is reserved for those leases, so high-bitrate rewind windows can be shorter. Manifests are capped at 1 MiB and segments at 32 MiB during receipt. Parsed playlists and retained session files are limited to 2,000 segments, with a minimum segment duration of 0.25 seconds. Open HTTP readers hold counted file leases until they close. Changing channels, stopping playback, or logging out removes the session; stale owned sessions are removed on next startup.

The player shows retained time and temporary bytes, rewind/forward controls, and a seek slider. Go Live appears after pause or rewind moves playback behind the normal live point. It also appears when ordinary playback falls more than 15 seconds behind. It seeks to a three-segment holdback before resuming. When paused content ages out, playback clamps to the oldest retained point. Missing capture intervals are marked as discontinuities with a visible notice.

Encrypted/DRM HLS, external audio/subtitle renditions, fragmented MP4 initialization maps, byte-range segments, and unsupported playlist types fall back to direct playback with a visible rewind-unavailable reason. Supported master playlists use one muxed variant, preferring the highest bitrate at or below 8 Mbps. This initial recorder does not provide adaptive variant switching. A native decoder or unsupported-format failure in the recorded variant triggers one attempt to play the original provider URL directly, with a visible rewind-unavailable reason. The recorder closes before direct playback starts, and playback intent is preserved.

On iPhone and iPad, paused capture is **not guaranteed when the app is backgrounded or the device is locked**. The operating system can suspend the app. Active background audio playback uses the existing audio mode. Capture resumes when the app becomes active; content missed during suspension cannot be recovered from an expired upstream window. Mac Catalyst can capture while its process remains active, excluding sleep or termination. The Catalyst-only entitlement file enables sandbox network client/server access for the loopback server; iOS uses its original entitlements.

Before release, use a signed native build to run the controlled moving HLS fixture described in the repository README. Confirm on iPhone, iPad, and Mac Catalyst: pause for longer than the provider's playlist window; manually retry the player while delayed and verify the playhead stays on the same recorded content; verify saved bytes increase while the picture remains paused; resume and rewind into content already expired upstream; seek forward and use Go Live; run past the retention and storage caps; change channels and log out; background/lock and resume; reject unsupported streams without losing ordinary playback. Confirm the Catalyst network entitlements with the signed app. Compilation and portable Swift tests do not validate AVPlayer or Network.framework runtime behavior.

## Linux builds and delivery

The Linux path uses the BruTV xtool fork's platform support. It builds the full app from the same Swift sources as the Xcode application target, checks source-list parity, and reads each target's bundle identifier and version from the Xcode Release settings. It compiles iOS/Catalyst icon assets and layered tvOS branding, builds the tvOS TopShelf extension, and creates a universal Catalyst executable. The default portable `Package.swift` behavior remains unchanged.

The tested fork is [bvolpato/xtool at `e3c6153`](https://github.com/bvolpato/xtool/commit/e3c615391817cde2512a38118a064f834ff64a32), on `codex/linux-apple-platforms`. [Upstream PR #362](https://github.com/xtool-org/xtool/pull/362) contains the platform changes. Until they are merged, point `XTOOL_SOURCE_DIR` at that checkout rather than upstream `main`. The current SDK metadata format is epoch 5; rebuild an older SDK with this fork before releasing.

The resource compiler pins [bvolpato/AssetKit at `cc948c7`](https://github.com/bvolpato/AssetKit/commit/cc948c71491a78183a08759dc07d4faef07ecad4). Its [macOS validation](https://github.com/bvolpato/AssetKit/actions/runs/40171617399) passed Apple's `assetutil` parser check for the tvOS layer-stack catalog. BruTV preserves the primary icon layers, marketing icon, and standard/wide Top Shelf roles. The generated TopShelf product uses the same sources, app group, version, and deployment target as the Xcode extension. Its principal class is retained when the extension library is linked.

**Release parity is not yet established.** Compilation, CAR parsing, and signing checks do not prove native tvOS icon loading/focus effects, Apple TV PiP/audio, Mac package acceptance, or App Store Connect processing. All requested targets and credentials must pass preflight; the release command never silently omits a platform or uploads an incomplete requested set. Physical-device validation remains required before submission.

Install the Apple SDK from an Xcode archive downloaded through your Apple Developer account, then install signing tools privately in the ignored build directory:

```bash
export XTOOL_SOURCE_DIR=/path/to/the/brutv-xtool-fork
./mobile/ios/BruTV/setup-linux.sh /path/to/Xcode_27.2.xip
./mobile/ios/BruTV/setup-linux.sh --signing-tools
./mobile/ios/BruTV/setup-linux.sh --catalyst-linker
```

The repository provides Docker-backed Swift 6.4 and xtool wrappers when native tools are unavailable. Linux builds also require `uv` to read and validate the selected SDK metadata. SDKs and caches stay in `mobile/ios/BruTV/build/linux-tools/`; `BRUTV_TOOLS_DIR` selects another isolated tool/SDK cache. `SWIFT_BINARY`, `XTOOL_BINARY`, and `XTOOL_SOURCE_DIR` select existing tools or a local fork checkout. Release builds require the fork's platform support and accurate SDK metadata, including the AppleTVOS SDK for tvOS. `BRUTV_BUILD_JOBS` limits toolchain concurrency (default 4). Release builds also produce `BruTV.app.dSYM` beside the unsigned app for crash symbolication, and tvOS adds `BruTVTopShelf.appex.dSYM`.

The Catalyst linker installer extracts only `lld` and its `ld64.lld` alias from the official LLVM 23.1.3 release after checking its pinned SHA-256. This includes [LLVM's fix for arm64e SDK reexports](https://github.com/llvm/llvm-project/pull/193065), which the current Apple SDK needs. The wrappers select the private linker automatically. `XTOOL_LD64_LLD` selects another executable; `BRUTV_LLVM_TOOLS_DIR` changes its installation directory. `BRUTV_LLVM_ARCHIVE` can reuse a downloaded official archive, with the same checksum check.

```bash
# Unsigned device apps, suitable for compilation checks.
./mobile/ios/BruTV/build.sh ios
./mobile/ios/BruTV/build.sh tvos
./mobile/ios/BruTV/build.sh macos

# Compile resources and stage sources without an Apple SDK.
./mobile/ios/BruTV/linux-build.sh --platform ios --prepare-only

# Validate credentials, tools, and all requested SDKs before building.
./mobile/ios/BruTV/release.sh --platform ios --preflight --upload

# Build, distribution-sign, and upload one explicitly selected platform.
IOS_BUILD_NUMBER=16 ./mobile/ios/BruTV/release.sh --platform ios --upload
```

`release.sh` defaults to `--platform all` (iOS, Catalyst, tvOS). Select one platform explicitly for a subset. Linux never invokes a simulator; `--skip-simulator-build` is accepted for compatibility. Every requested package is built, signed, and checked before the first upload. If Apple rejects a later upload, previous uploads cannot be rolled back automatically. On Linux, a successful upload requires the Build Upload API to complete and the linked build to become `VALID`. Native Xcode delivery must also be followed by App Store Connect processing verification. Uploading does not submit the app for review or publish it.

Distribution credentials are required independently of xtool's on-device development authentication:

| Platform | Required configuration |
| --- | --- |
| iOS/iPadOS | `IOS_CERTIFICATE_PATH`, `IOS_P12_PASSWORD`, `IOS_PROVISIONING_PROFILE_PATH` |
| tvOS | Shared distribution certificate plus `TVOS_PROVISIONING_PROFILE_PATH` and `TVOS_TOPSHELF_PROVISIONING_PROFILE_PATH`; both profiles must authorize `group.com.bvolpato.brutv` |
| Mac Catalyst | `MACOS_APPLICATION_CERTIFICATE_PATH`, `MACOS_APPLICATION_P12_PASSWORD`, `MACOS_INSTALLER_CERTIFICATE_PATH`, `MACOS_INSTALLER_P12_PASSWORD`, `MACOS_PROVISIONING_PROFILE_PATH` |
| App Store Connect upload | `IOS_ASC_KEY_ID`, `IOS_ASC_ISSUER_ID`, `IOS_ASC_PRIVATE_KEY_PATH` (unencrypted P-256 `.p8` key); `ASC_*` aliases are accepted |

Certificate and provisioning profile variables also accept `_BASE64` in place of `_PATH`. Do not put passwords or key contents in command arguments. iOS/tvOS use the private zsign installation; Mac Catalyst uses rcodesign and genuine BOM/CPIO/XAR installer tools. The helpers verify distribution profiles, certificate trust, entitlements, executable signatures, sealed resources, and installer checksums. They preserve an existing output if signing fails. `upload-build.py --validate-only` validates package structure offline; cryptographic verification belongs to the signing helper.

## macOS prerequisites

- **macOS** with **Xcode 27.2+** and the corresponding platform SDKs.
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

Run the full unit and UI test suite on a Mac with Xcode 27.2 or later:

```bash
./mobile/ios/BruTV/test.sh
```

Default UI tests use `--ui-fixtures`: a debug-only offline transport supplies synthetic authentication, catalogs, and playlists. Media controls use a generated local silent WAV file. This verifies navigation and player lifecycle without provider credentials or network access; it does not establish decoded-video quality.

Debug `--demo-login` and `--play-demo` launches also use these fixtures unless all three provider credential variables are supplied. The test-credential fill button appears only in explicit fixture mode.

The optional `testLiveChannelShowsVideoInPlayerAndMiniPlayer` test requires `TEST_RUNNER_BRUTV_PLAYBACK_SERVER`, `TEST_RUNNER_BRUTV_PLAYBACK_USERNAME`, `TEST_RUNNER_BRUTV_PLAYBACK_PASSWORD`, and `TEST_RUNNER_BRUTV_PLAYBACK_CHANNEL` in the environment passed to `xcodebuild`. It skips when any value is missing. Supply credentials through the environment and keep them out of scripts and logs.

`testNavigationAndPlaybackSurviveResizing` checks navigation, filters, and mini-player continuity during rotation. `testPlayerControlsFitAfterRotation` checks that transport controls and the channel-guide close button stay inside the window and remain tappable. CI builds every Apple target with Xcode 27.2. The iPhone and iPad suites select the iOS 27.2 runtime; Duo selects its working iOS 27.1 runtime. On the current runner, creating Duo with iOS 27.2 fails with CoreSimulator error 403, `Incompatible device`. CI creates a named simulator when the selected runtime has no existing instance, using the exact registered device type.

CI verifies Xcode's stable build number, `27B52`, because an older runner image mapped `Xcode_27.2.app` to the release candidate. GitHub's [November 4 Xcode 27 runner image](https://github.com/actions/runner-images/releases/tag/xcode-27-arm64/20261104.0337) includes the stable build and iOS 27.2 runtime. A fresh CI run must confirm the runner actually has them.

To select Duo locally:

```bash
IOS_SIM_DESTINATION="platform=iOS Simulator,name=iPhone Duo,OS=27.1" ./test.sh
```

A default Duo launch and rotation do not exercise every pose. In Xcode 27.2 Device Hub, open, close, and partially fold the device, then use Split View while browsing and playing media. Check asymmetric safe areas, large text, VoiceOver, narrow guide drawers, and navigation between sections. Native tabs and toolbars choose their edge and overflow behavior; do not force them into a custom right-side bar. Confirm that the video keeps playing, paused intent and search remain intact, and controls avoid the camera and fold. Physical-device video, audio, PiP, accessibility, and fold transitions remain separate release checks. See [Apple's Duo guidance](https://developer.apple.com/iphone-duo/prepare/).

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

Capture Mac Catalyst screenshots from the running native app on macOS. The optional `generate_mac_screenshots.py` helper creates concept mockups from iPad images under `build/mockups/`; it is excluded from the store capture workflow and does not provide native UI evidence.

---

## 4. Building the Signed App Store IPA

The script has two signing modes.

On macOS and Linux, select `--platform ios`, `macos`, or `tvos` for one platform, or `all` for the complete set. Run `--preflight` before building. It checks the tools, signing inputs, and target mappings without creating an archive or uploading a package.

**Automatic on macOS.** Set `IOS_SIGNING=automatic` to use the configured Xcode account and keychain identities. You need two things:

- The Apple ID is signed in to Xcode (Settings > Accounts).
- The login keychain has an Apple Distribution certificate for team `83BXSDT7QC`. To create one, go to Accounts > Manage Certificates > + > Apple Distribution.

Xcode creates the App Store profile.

```bash
IOS_SIGNING=automatic ./mobile/ios/BruTV/release.sh --platform all --preflight
IOS_SIGNING=automatic ./mobile/ios/BruTV/release.sh --platform all --skip-simulator-build
```

**Manual.** For iOS, put the distribution certificate (`.p12`) and App Store provisioning profile in `mobile/ios/BruTV/signing/`, or select them with `IOS_CERTIFICATE_PATH` and `IOS_PROVISIONING_PROFILE_PATH`. Git ignores signing files. The script reads the profile name and team ID from the profile.

```bash
IOS_P12_PASSWORD='<password>' ./mobile/ios/BruTV/release.sh --platform ios --skip-simulator-build
```

Manual Catalyst and tvOS releases require their own profiles. Set `MACOS_PROVISIONING_PROFILE_PATH`, `TVOS_PROVISIONING_PROFILE_PATH`, and `TVOS_TOPSHELF_PROVISIONING_PROFILE_PATH` for the requested targets. tvOS maps the app and TopShelf extension separately; both profiles must authorize their exact bundle identifiers and shared app group. Catalyst requires compatible application and installer identities. Import them with `MACOS_APPLICATION_CERTIFICATE_PATH` / `MACOS_APPLICATION_P12_PASSWORD` and `MACOS_INSTALLER_CERTIFICATE_PATH` / `MACOS_INSTALLER_P12_PASSWORD`, or use valid identities already in the macOS keychain.

On macOS, `MACOS_CODE_SIGN_IDENTITY` can select an existing Mac App Distribution or legacy 3rd Party Mac Developer Application identity when its name differs from Apple Distribution. Profile expiration and certificate membership are checked before archiving.

In CI, certificate/profile variables also accept `_BASE64` instead of `_PATH`. `IOS_SIGNING`, `IOS_TEAM_ID`, `IOS_BUILD_NUMBER`, and `IOS_MARKETING_VERSION` override the defaults.

On macOS, every run gets a new `mobile/ios/BruTV/build/release/run.XXXXXX/` directory, with a separate archive and export directory for each requested platform. The script prints the exact package paths. Previous artifacts are preserved when a later build or export fails. In manual mode, it signs in a temporary keychain. Linux package paths remain under `build/release/export/` unless `IOS_RELEASE_DIR` overrides the build directory.

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
IOS_IPA_PATH="/absolute/path/printed/by/release.sh/ios/export/BruTV.ipa"
xcrun altool --upload-app -f "$IOS_IPA_PATH" -t ios --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

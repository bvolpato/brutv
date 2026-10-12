# BruTV for Vega OS

This is a source starter for Vega OS televisions. Android and Fire OS use the Android project in `../android`. A Vega device needs a native `.vpkg`; an Android APK downloaded through Downloader does not run on Vega OS.

The starter uses Amazon's React Native 0.72 track and SDK 0.23 project/media conventions. It has provider sign-in, M3U URL import, the iOS `brutv://login` wire format, Xtream live/movie/series catalogs, episodes, category and text search, session favorites/recents, visible remote focus, and a W3C media screen. There are no bundled provider accounts, streams or catalog feeds.

HLS and DASH use Amazon-patched Shaka with adaptive bitrate enabled. MP4 uses the same W3C media surface. Decoder support depends on the device and codec. Raw MPEG-TS and MKV sources are explicitly rejected in this starter. Playback retries are bounded, a screen exit cancels scheduled retries, and player resources are released on exit or backgrounding. These policies are source-level behavior, not measured hardware performance or a guarantee against provider/network buffering.

## Current validation

On Linux, the public npm dependencies install without a Vega SDK. `npm test` validates sign-in encoding, nested URL decoding, M3U metadata and identity, filtering, provider catalogs/episodes, playback initialization ordering, retry cancellation and teardown using fake media elements. `npm run setup:shaka` compiles the actual Amazon-patched Shaka source, and `npm run typecheck` checks BruTV's UI and adapter against the real npm API declarations. A production-mode Metro JavaScript bundle for platform `kepler` also succeeds. Vendor polyfills retain the sample's `@ts-nocheck` boundary and are not covered by the TypeScript claim.

No Vega SDK, VPKG, emulator or physical device was used. TV focus, native decoding, secure storage, system media keys and Appstore certification remain unverified. Do not publish this starter as a tested Vega app.

## Local source checks

Use Node 18 or 20 for the documented SDK track, Java 21+, Python 3 and Git. Node 22 was used for the source checks above. The shell helper uses upstream Shaka's own Python build, which manages its build dependencies. It builds in a new temporary checkout and writes only ignored generated artifacts inside this project.

```sh
cd mobile/vega
npm ci --ignore-scripts
npm test
npm run setup:shaka
npm run typecheck
```

`setup:shaka` is an explicit step. It does not install the Vega SDK. Its generated `src/media/shaka/` directory is required before TypeScript checking or Metro/native builds; it is reproducible from the checked-in source archive and upstream tag.

## Native build and run

Install and activate [Vega Developer Tools](https://developer.amazon.com/docs/vega/0.23/install-vega-sdk.html) on a supported Mac or Linux workstation. Activate SDK 0.23 and check `vega --version`. This starter intentionally follows the [official v0.23.0 video sample](https://github.com/AmazonAppDev/vega-video-sample/tree/v0.23.0), whose release build command is `react-native build-kepler --build-type Release`. The SDK must resolve its system distributed libraries and generated manifest entries before packaging. The SDK and platform installer were not run here.

```sh
npm ci
npm run setup:shaka
npm run typecheck
vega exec vpt validate "$PWD/manifest.toml"
npm run build:app
vega virtual-device start
```

The sample generates architecture-specific files under `build`. Use `armv7` for a Vega Fire TV Stick, `x86_64` for an Intel/Linux virtual device, or `aarch64` for a Mac Apple Silicon virtual device. After finding the generated package, run Amazon's documented command with its actual path:

```sh
vega run-app <path-to-built-package.vpkg>
```

See [run on Vega Virtual Device or Fire TV](https://developer.amazon.com/docs/vega/0.23/run-apps.html) for developer mode, device setup and remote keyboard mappings. The file name is produced by the SDK; do not rename an APK to `.vpkg`.

SDK 0.24 introduces an OS 1.2 minimum/target manifest declaration and an early-access React Native 0.83 track. [Amazon's release notes](https://developer.amazon.com/docs/vega/0.24/vega-release-notes.html) explain this compatibility boundary. This starter has not been migrated to or tested with that track. An SDK 0.24 build needs its matching template/dependencies and OS manifest settings, rather than an unreviewed version bump. The 0.23 source track does not establish an OS 1.1 compatibility guarantee: package generation and testing on each claimed device/OS version are still required. There is no validated minimum device OS for this source-only starter.

## Sign-in and parity boundaries

- Paste an M3U URL, a Xtream `get.php` URL, or the exact text encoded in an iOS sign-in QR code. Xtream provider accounts can also be entered manually. Query decoding preserves a literal `+` and performs one percent-decoding pass.
- The decoder accepts existing iOS links, including explicit server paths. Android, Vega, and the updated iOS converter retain a panel path when converting `/panel/get.php`.
- Vega televisions usually have no camera. This starter accepts the QR payload as text; it does not pretend to scan from a TV camera or provide a phone pairing service. Android's camera scanner is in the Android project. System deep-link registration for `brutv:` on Vega is also not implemented; the manual importer is the tested boundary.
- Credentials, favorites and recents are session-only. There is no plaintext on-disk credential storage. No documented secure-storage API was wired in this starter, so ending the app process clears local session state. Provider credentials and URLs are sent directly to the user-selected provider; HTTP providers do not encrypt those requests.
- M3U files are fetched from user-supplied HTTP(S) URLs. Device-local file picking is not included. Existing playlist parsing mirrors iOS names, quoted attributes, first semicolon-delimited category and stable FNV-1a identities, but Vega renders those 64-bit identities as hex strings to avoid JavaScript precision loss.
- Catalog requests have a 20-second overall deadline and cancellation. Large playlist downloads still parse on the JS thread; a worker/native parsing design and memory profiling are required for very large provider catalogs.

## Before release

Run a native build and emulator smoke test, then test real hardware before distribution. Verify remote navigation across long catalogs, input/keyboard behavior, media keys, pause/seek/live behavior, app suspend/resume, decoder release, subtitle/audio tracks, network drops, adaptive rendition switching and low-memory behavior. Add platform media-controls integration and confirmed secure credential storage before promising parity with the finished Android/iOS apps. Measure startup-to-first-frame, rebuffers, JS-frame latency and memory on the actual stick.

The SDK 0.23 / RN 0.72 dependency graph fails the release security gate. `npm audit --omit=dev` reports 64 dependency findings, including 35 high and 5 critical. That command audits the entire declared production dependency tree, which includes code-generation and CLI tools; it does not identify only code emitted into the app.

The critical chain is `@amazon-devices/react-native-w3cmedia@2.1.99` → `react-native-tscodegen-types@0.66.0` → nested `react-native@0.60.6` → `@react-native-community/cli@2.10.0` → `cli-platform-android@2.9.0` → `logkitty@0.6.1`, with a nested `shell-quote@1.6.1`. The direct critical advisories cover [logkitty shell execution](https://github.com/advisories/GHSA-v8v8-6859-qxm4) and [shell-quote command injection](https://github.com/advisories/GHSA-w7jw-789q-3m8p); React Native and CLI receive propagated critical labels. The nested old React Native also has a direct high ReDoS advisory.

The production-mode Metro source map contains 621 source modules. None of the critical CLI/logkitty/shell-quote paths, or the nested `react-native-tscodegen-types` tree, appear in that JavaScript bundle. It uses Amazon's `react-native-kepler` runtime namespace. The five Amazon packages with propagated high labels in the source map inherit those labels through codegen/CLI dependencies, with no direct advisory leaf package present in the bundle's source list. This is a bounded JavaScript bundle finding; it does not audit the SDK's native/system-distributed binaries, exercise exploitability, or approve release.

The source uses maintained `@xmldom/xmldom` instead of the old sample's deprecated `xmldom` parser, with no audit entry for the maintained parser. Before release, address the build-chain advisories, inspect the final VPKG/native dependencies, and evaluate the official SDK 0.24 / RN 0.83 migration with its OS 1.2 device restriction. A newer track is the recommended follow-up, but its security result must be measured rather than assumed. `npm audit fix --force` would cross platform compatibility boundaries and was not applied.

For Appstore distribution, follow [Amazon's Vega submission guide](https://developer.amazon.com/docs/vega/0.23/app-submission.html). Set increasing package version/build numbers using the selected SDK's documented build flags, inspect them with `vega exec vpt info <path-to-vpkg> --json`, supply app icon/screenshots/support/privacy details and complete certification. There is no Appstore record, signing configuration or release package prepared by this source-only work.

## Source provenance

Template conventions and API integration derive from `AmazonAppDev/vega-video-sample` tag `v0.23.0`, commit `20e2ac87e7f883413c6d05fa34c4be9f2a05a87d`. The updated patched Shaka archive is linked by [Amazon's SDK 0.23 Shaka guide](https://developer.amazon.com/docs/vega/0.23/media-player-shaka-player.html). `vendor/amazon/README.md` records the source URL and licenses. The app icon is the existing BruTV iOS icon copied into this target. Native media APIs follow [Media Player Setup](https://developer.amazon.com/docs/vega/0.23/media-player-setup.html) and [Focus Management](https://developer.amazon.com/docs/vega/0.23/focus-management.html).

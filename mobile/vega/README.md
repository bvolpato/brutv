# BruTV for Vega OS

This is a source starter for Vega OS televisions. Android and Fire OS use the Android project in `../android`. A Vega device needs a native `.vpkg`; an Android APK downloaded through Downloader does not run on Vega OS.

The starter uses Amazon's React Native 0.72 track and SDK 0.23 project/media conventions. It has provider sign-in, M3U URL import, the iOS `brutv://login` wire format, Xtream live/movie/series catalogs, episodes, category and text search, session favorites/recents, visible remote focus, and a W3C media screen. There are no bundled provider accounts, streams or catalog feeds.

HLS and DASH use Amazon-patched Shaka with adaptive bitrate enabled. MP4 uses the same W3C media surface. Decoder support depends on the device and codec. Raw MPEG-TS and MKV sources are explicitly rejected in this starter. Playback retries are bounded, a screen exit cancels scheduled retries, and player resources are released on exit or backgrounding. These policies are source-level behavior, not measured hardware performance or a guarantee against provider/network buffering.

## Live pause and rewind

Clear, muxed HLS live channels can record continuously while the viewer pauses or rewinds. The recorder polls independently of the playback element and writes media segments to app-private `/tmp` files through the [SDK 0.23 File System API](https://developer.amazon.com/ja/docs/vega-api/0.23/README.amazon-devices_kepler-file-system.html). The documented API exposes string IO, so segment files use base64. Shaka reads and decodes those files through a session-specific `brutv-timeshift:` networking scheme. Original provider URLs and credentials stay in memory and are not written into the recording files or generated local manifest.

The rolling buffer retains at most 10 minutes and 256 MiB of encoded files, whichever limit is reached first. The byte cap includes the fMP4 initialization segment and base64 overhead. Each segment or initialization response is limited to 8 MiB; playlists are limited to 1 MiB. Downloads are serialized, disk reads are serialized with a bounded queue, and requests have a 15-second deadline. Startup captures the latest six available segments instead of downloading an entire provider archive before opening playback. When the saved pause position expires, the player stays paused at the earliest available point and explains what happened. Rewind and forward move 10 seconds within Shaka's actual seek range. Go live returns to the normal presentation-delay position and resumes playback. Generated date tags and an explicit captured-content origin preserve the held position when a retry reloads a retained manifest with a new player time origin.

Vega's patched fetch allocates whole response buffers. Recording therefore requires an accurate, positive `Content-Length` before reading a body, and refuses compressed, unknown-size or oversized responses. Unsupported recording streams play directly with a visible explanation. Encrypted HLS, separate audio/subtitle renditions, byte ranges, low-latency partial or delta playlists, changing initialization segments and ended playlists are excluded from local recording. DASH and MP4 retain direct playback. For an eligible master playlist, recording fixes one muxed rendition, choosing the highest declared bandwidth at or below 8 Mbps, or the smallest variant if all exceed that value. Adaptive switching remains available in direct playback.

If the recorded rendition fails to load, or Shaka reports a critical media, manifest, or local-buffer network error during recorded playback, the app closes its local recorder and falls back once to the original source. The player shows that local rewind is unavailable, retains the original master and its tracks, and does not recreate the recorder on later retries in that session. Paused intent is preserved during this transition. This fallback handles a fixed recording rendition that the device cannot decode even when the original adaptive master has a playable alternative.

The recorder stops and removes its files on channel/player exit and when the app becomes inactive. It does not claim continued recording while Vega suspends the app. Startup removes only files with BruTV's recording prefix left by an interrupted prior run. Nothing is retained across an app restart as watchable content. Temp-storage failure stops recording; provider failures get bounded retries, then direct playback fallback.

## Current validation

On Linux, the public npm dependencies install without a Vega SDK. `npm test` validates sign-in encoding, nested URL decoding, M3U metadata and identity, filtering, provider catalogs/episodes, playback initialization ordering, paused retry intent, live seeking, expired pause feedback, recorder ingestion without a playback consumer, file retention, encoded byte caps, download limits and cancellation using fake media, network and storage adapters. `npm run setup:shaka` compiles the actual Amazon-patched Shaka source, and `npm run typecheck` checks BruTV's UI, filesystem and media adapters against the real npm API declarations. A production-mode Metro JavaScript bundle for platform `kepler` also succeeds. Vendor polyfills retain the sample's `@ts-nocheck` boundary and are not covered by the TypeScript claim.

SDK 0.23.9221 produces validated armv7 and x86_64 VPKGs for version 1.0.0, build 3. The candidate uses the frozen build 2 source with a scoped remote Play/Pause key fix. Package generation, source tests, type checking, and VPT validation pass. The official virtual device also passes sign-in, a local M3U/HLS fixture, remote navigation, favorites, pause/resume, Back, and background teardown without foreground autoplay. Native playback time and buffered ranges advance; decoded video pixels and audio remain unverified. Local rewind falls back to provider-direct playback in the emulator. Physical-device playback, temporary-file IO, Shaka custom-scheme playback, secure storage, full system media controls, and Appstore certification remain unverified. SDK initialization and polyfill warnings remain. These checks do not establish a finished or hardware-tested Vega release.

## Local source checks

Use Node 22 and npm 11.10 or later, Java 21+, Python 3 and Git. The shell helper uses upstream Shaka's own Python build, which manages its build dependencies. It builds in a new temporary checkout and writes only ignored generated artifacts inside this project.

```sh
cd mobile/vega
npm ci --ignore-scripts
npm test
npm run setup:shaka
npm run typecheck
npm run bundle -- --platform kepler --entry-file index.js --dev false --bundle-output build/ci/index.bundle --assets-dest build/ci/assets --max-workers 2
```

`setup:shaka` is an explicit step. It compiles the release player library and TypeScript declarations without building the unused upstream UI, demos, or debug variants. It does not install the Vega SDK. Its generated `src/media/shaka/` directory is required before TypeScript checking or Metro/native builds; it is reproducible from the checked-in source archive and upstream tag. Tests, bundling, and native build scripts run `setup:metro` to adapt the locked Metro 0.76 installations to image-size 2. Direct React Native CLI use after a clean install requires `npm run setup:metro` first.

## Native build and run

Install and activate [Vega Developer Tools](https://developer.amazon.com/docs/vega/0.23/install-vega-sdk.html) on a supported Mac or Linux workstation. Activate SDK 0.23 and check `vega --version`. This target follows the [official v0.23.0 video sample](https://github.com/AmazonAppDev/vega-video-sample/tree/v0.23.0). The SDK must resolve its system distributed libraries and generated manifest entries before packaging. Local packaging was validated with SDK 0.23.9221 on Linux.

```sh
npm ci
npm run setup:shaka
npm run typecheck
vega exec vpt validate "$PWD/manifest.toml"
npm run build:app
vega virtual-device start
```

For a versioned release candidate, run `./release.sh` with SDK 0.23 active. It installs the locked npm dependencies, runs source checks, regenerates patched Shaka, builds the native package, validates it with VPT, and verifies its package ID, version, and build number. It writes `build/distributions/BruTV-vega-armv7-1.0.0-3.vpkg`. Set `BRUTV_VEGA_TARGET=x86_64` for a Linux virtual device or `BRUTV_VEGA_BUILD_NUMBER` for a later build. Device testing and Appstore submission are separate gates.

The sample generates architecture-specific files under `build`. Use `armv7` for a Vega Fire TV Stick, `x86_64` for an Intel/Linux virtual device, or `aarch64` for a Mac Apple Silicon virtual device. After finding the generated package, run Amazon's documented command with its actual path:

```sh
vega run-app <path-to-built-package.vpkg>
```

See [run on Vega Virtual Device or Fire TV](https://developer.amazon.com/docs/vega/0.23/run-apps.html) for developer mode, device setup and remote keyboard mappings. The file name is produced by the SDK; do not rename an APK to `.vpkg`.

SDK 0.24 introduces an OS 1.2 minimum/target manifest declaration and an early-access React Native 0.83 track. [Amazon's release notes](https://developer.amazon.com/docs/vega/0.24/vega-release-notes.html) explain this compatibility boundary. This starter has not been migrated to or tested with that track. An SDK 0.24 build needs its matching template/dependencies and OS manifest settings, rather than an unreviewed version bump. The 0.23 source track does not establish an OS 1.1 compatibility guarantee: package generation and testing on each claimed device/OS version are still required. There is no validated minimum device OS for this target.

## Sign-in and parity boundaries

- Paste an M3U URL, a Xtream `get.php` URL, or the exact text encoded in an iOS sign-in QR code. Xtream provider accounts can also be entered manually. Query decoding preserves a literal `+` and performs one percent-decoding pass.
- The decoder accepts existing iOS links, including explicit server paths. Android, Vega, and the updated iOS converter retain a panel path when converting `/panel/get.php`.
- Vega televisions usually have no camera. This starter accepts the QR payload as text; it does not pretend to scan from a TV camera or provide a phone pairing service. Android's camera scanner is in the Android project. System deep-link registration for `brutv:` on Vega is also not implemented; the manual importer is the tested boundary.
- Credentials, favorites and recents are session-only. There is no plaintext on-disk credential storage. No documented secure-storage API was wired in this starter, so ending the app process clears local session state. Provider credentials and URLs are sent directly to the user-selected provider; HTTP providers do not encrypt those requests.
- M3U files are fetched from user-supplied HTTP(S) URLs. Device-local file picking is not included. Existing playlist parsing mirrors iOS names, quoted attributes, first semicolon-delimited category and stable FNV-1a identities, but Vega renders those 64-bit identities as hex strings to avoid JavaScript precision loss.
- Catalog requests have a 20-second overall deadline and cancellation. Large playlist downloads still parse on the JS thread; a worker/native parsing design and memory profiling are required for very large provider catalogs.

## Before release

Run a native build and emulator smoke test, then test real hardware before distribution. Verify remote navigation across long catalogs, input/keyboard behavior, media keys, pause/seek/live behavior, app suspend/resume, decoder release, subtitle/audio tracks, network drops, adaptive rendition switching and low-memory behavior. Add platform media-controls integration and confirmed secure credential storage before promising parity with the finished Android/iOS apps. Measure startup-to-first-frame, rebuffers, JS-frame latency and memory on the actual stick.

The dependency hardening retains SDK 0.23, React Native 0.72, and React 18.2. W3C Media 2.2.21 removes the obsolete code-generation dependencies, as described in [Amazon's security fix](https://www.developer.amazon.com/docs/vega/0.22/vega-release-notes). It requires the `IW3cmedia_2` system interface on Vega OS 1.1 build 4459 or later. The package set still needs native packaging and physical-device playback validation before distribution; earlier native candidate results do not validate these dependency changes.

The CLI is aligned to the compatible 11.4.1 release, removing its vulnerable `ip` dependency. Locked overrides select patched `fast-xml-parser`, `image-size`, `lodash`, and `toml` releases. The Metro compatibility patch adapts the image-size named export and converts file-path inputs to buffers. It fails if a different Metro version needs review. Tests read the real app icon through every locked Metro installation.

On October 28, 2026, both the full dependency audit and `npm audit --omit=dev` report no critical, high, or moderate findings. Six low-severity package entries propagate one unpatched [deepmerge advisory, GHSA-gcqx-w48m-w2h4](https://github.com/advisories/GHSA-gcqx-w48m-w2h4), through React Native's CLI configuration dependencies. No alert is suppressed. A compatible upstream fix remains required.

The npm audit covers the declared dependency tree, including CLI and build tools. It does not establish which code ships in a VPKG or whether a particular stream can exploit it. Regenerate and inspect the final VPKG and native dependencies before release. A future SDK 0.24 / RN 0.83 migration also needs its matching dependency/template set and OS 1.2 validation; `npm audit fix --force` is not a substitute for that migration.

For Appstore distribution, follow [Amazon's Vega submission guide](https://developer.amazon.com/docs/vega/0.23/app-submission.html). Set increasing package version/build numbers, inspect them with `vega exec vpt info <path-to-vpkg> --json`, supply app icon/screenshots/support/privacy details, and complete certification. Amazon requires testing on a physical Fire TV Stick before submission. Open the [Appstore App List](https://developer.amazon.com/apps-and-games/console/apps/list.html#/) for submissions. The general CMS root returned `User not authorized`, but the Appstore-specific route is accessible. Account identity verification is cleared. Amazon confirms that the armv7 build 3 submission is Under Review, with descriptions, genuine emulator screenshots, privacy disclosures, and transparent review instructions. Physical-device video and audio validation remain unverified. The Live App Testing form prohibits personal-information collection; provider authentication is disclosed, so that beta draft remains unsubmitted. Amazon approval and public availability have not been confirmed.

## Source provenance

Template conventions and API integration derive from `AmazonAppDev/vega-video-sample` tag `v0.23.0`, commit `20e2ac87e7f883413c6d05fa34c4be9f2a05a87d`. The updated patched Shaka archive is linked by [Amazon's SDK 0.23 Shaka guide](https://developer.amazon.com/docs/vega/0.23/media-player-shaka-player.html). `vendor/amazon/README.md` records the source URL and licenses. The app icon is the existing BruTV iOS icon copied into this target. Native media APIs follow [Media Player Setup](https://developer.amazon.com/docs/vega/0.23/media-player-setup.html) and [Focus Management](https://developer.amazon.com/docs/vega/0.23/focus-management.html).

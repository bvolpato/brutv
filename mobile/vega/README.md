# BruTV for Vega OS

BruTV for Vega OS televisions uses Amazon's React Native 0.72 track and SDK 0.23 project/media conventions. Android and Fire OS use the Android project in `../android`. A Vega device needs a native `.vpkg`; an Android APK downloaded through Downloader does not run on Vega OS.

The app provides provider sign-in, M3U URL import, the iOS `brutv://login` wire format, lazy-loaded Xtream live/movie/series catalogs, episodes with numeric season/episode ordering, on-demand Now/Next EPG, category and debounced text search, saved favorites/recents/VOD resume positions, opt-in local sign-in persistence, visible remote focus, and a W3C media screen with captions and audio/subtitle track selection. There are no bundled provider accounts, streams, or catalog feeds.

HLS and DASH use Amazon-patched Shaka with adaptive bitrate enabled. MP4 uses the same W3C media surface. Decoder support depends on the device and codec. Raw MPEG-TS and MKV sources are explicitly rejected. Playback retries are bounded, channel switches reuse the active `VideoPlayer` and `shaka.Player` instance without remounting, a screen exit cancels scheduled retries, transient backgrounding pauses playback, and memory warnings shed local buffers before closing. These policies are source-level behavior, not measured hardware performance or a guarantee against provider/network buffering.

## Live zapping, pause, and rewind

Live TV channels launch directly in Shaka for instant first-frame playback with full adaptive bitrate switching (`rebufferingGoal: 2.5s`). Clear, muxed HLS live channels start local recording lazily when the viewer pauses or initiates rewind, instead of blocking initial playback on startup segment downloads.

When active, the recorder polls independently of the playback element, serves live-edge segments directly from an in-memory `Uint8Array` tail ring, and writes older history to a session directory under `/tmp/brutv-ts-<token>/` through the [SDK 0.23 File System API](https://developer.amazon.com/ja/docs/vega-api/0.23/README.amazon-devices_kepler-file-system.html). The documented API exposes string IO, so disk segment files use base64. Shaka reads those files through a session-specific `brutv-timeshift:` networking scheme. Original provider URLs and credentials stay in memory and are not written into recording files or generated local manifests.

The rolling buffer retains at most 10 minutes and 256 MiB of encoded files, whichever limit is reached first. The byte cap includes the fMP4 initialization segment and base64 overhead. Each segment or initialization response is limited to 8 MiB; playlists are limited to 1 MiB. Downloads are serialized, disk reads are serialized with a bounded queue, and requests have a 15-second deadline. Segment `#EXT-X-PROGRAM-DATE-TIME` and `#EXTINF` tags are cached on ingest rather than regenerated per manifest poll. When the saved pause position expires, the player stays paused at the earliest available point and explains what happened. Rewind and forward move 10 seconds within Shaka's actual seek range. Go live returns to the normal presentation-delay position and resumes playback.

Unsupported recording streams play directly with a visible explanation. Encrypted HLS, separate audio/subtitle renditions, byte ranges, low-latency partial or delta playlists, changing initialization segments, and ended playlists are excluded from local recording. DASH and MP4 retain direct playback. For an eligible master playlist, recording selects one muxed rendition (highest declared bandwidth at or below 8 Mbps, or the smallest variant if all exceed that value). Adaptive switching remains available in direct playback.

If a recorded rendition fails to load, or Shaka reports a critical media, manifest, or local-buffer network error during recorded playback, the app closes its local recorder and falls back once to the original source. Session cleanup removes `/tmp/brutv-ts-<token>/` in a single `removeDirAll` call decoupled from the next channel's `load()`. Startup removes stale BruTV recording directories or legacy files left by an interrupted prior run. Nothing is retained across an app restart as watchable content.

## Catalog loading and persistence

- **Section-partitioned lazy loading**: Xtream sign-in respects `user_info.allowed_output_formats` and fetches Live TV first (categories and streams in parallel). Movies and Series load lazily on tab switch with in-flight request deduplication and response byte caps (`32 MiB`). Provider category order is preserved and items are deduplicated by ID.
- **Stale-while-revalidate cache**: Xtream section metadata caches in `/data/brutv-cache-<sourceKey>-<section>.json` without storing playback URLs or credentials; URLs are reconstructed in memory on read.
- **Saved library & VOD resume**: Favorites, recents, language, and bounded VOD `resumePositions` (up to 50 entries, auto-cleared near completion) save in alternating validated `/data/brutv-library-v1-{a,b}.json` files using UTF-8 byte-length verification.
- **Opt-in saved sign-in**: Credentials stay session-only by default. Viewers can explicitly opt in to save their provider sign-in in app-private `/data/brutv-saved-source-v1.json`; signing out or disabling the option removes that file immediately.

## Local source checks

Use Node 22 and npm 11.21 or later, Java 21+, Python 3, and Git.

```sh
cd mobile/vega
npm ci --ignore-scripts
npm test
npm run setup:shaka
npm run typecheck
mkdir -p build/ci
npm run bundle -- --platform kepler --entry-file index.js --dev false --bundle-output build/ci/index.bundle --assets-dest build/ci/assets --max-workers 2
```

`setup:shaka` compiles the release player library and TypeScript declarations into `src/media/shaka/`. Tests, bundling, and native build scripts run `setup:all`: `setup:metro` adapts the locked Metro 0.76 installations to `image-size` 2, and `setup:deepmerge` applies the guarded local fix to the installed CLI dependency.

## Native build and run

Install and activate [Vega Developer Tools](https://developer.amazon.com/docs/vega/0.23/install-vega-sdk.html) on a supported Mac or Linux workstation. Activate SDK 0.23 and check `vega --version`. This target follows the [official v0.23.0 video sample](https://github.com/AmazonAppDev/vega-video-sample/tree/v0.23.0).

```sh
npm ci
npm run setup:shaka
npm run typecheck
vega exec vpt validate "$PWD/manifest.toml"
npm run build:app
vega virtual-device start
```

For a versioned release candidate, run `./release.sh` with SDK 0.23 active. Set `BRUTV_VEGA_TARGET=x86_64` for a Linux virtual device or `BRUTV_VEGA_BUILD_NUMBER` to a build number greater than the last submitted version. Device testing and Appstore submission are separate gates.

SDK 0.24 introduces an OS 1.2 minimum/target manifest declaration and an early-access React Native 0.83 track. [Amazon's release notes](https://developer.amazon.com/docs/vega/0.24/vega-release-notes.html) explain this compatibility boundary. This target has not been migrated to or tested with SDK 0.24.

## Sign-in and parity boundaries

- Paste an M3U URL, an Xtream `get.php` URL, or the exact text encoded in an iOS sign-in QR code. Xtream provider accounts can also be entered manually. Query decoding preserves a literal `+` and performs one percent-decoding pass.
- Vega televisions usually have no camera. BruTV on Vega accepts the QR payload as text and does not pretend to scan from a TV camera. System deep-link registration for `brutv:` on Vega is not implemented; the manual importer is the tested boundary.
- M3U files are fetched from user-supplied HTTP(S) URLs. Device-local file picking is not included. Playlist parsing mirrors iOS names, quoted attributes, first semicolon-delimited category, `tvg-id`, and stable 64-bit FNV-1a identities rendered as hex strings.

## Before release

Run a native build and emulator smoke test, then test real hardware before distribution. Verify remote navigation across long catalogs, input/keyboard behavior, media keys, channel zapping, auto-hiding player controls, pause/seek/live behavior, app suspend/resume, decoder release, captions (`KeplerCaptionsView`), subtitle/audio tracks, network drops, adaptive rendition switching, and low-memory behavior.

## Source provenance

Template conventions and API integration derive from `AmazonAppDev/vega-video-sample` tag `v0.23.0`, commit `20e2ac87e7f883413c6d05fa34c4be9f2a05a87d`. The updated patched Shaka archive is linked by [Amazon's SDK 0.23 Shaka guide](https://developer.amazon.com/docs/vega/0.23/media-player-shaka-player.html). `vendor/amazon/README.md` records the source URL and licenses. Native media APIs follow [Media Player Setup](https://developer.amazon.com/docs/vega/0.23/media-player-setup.html) and [Focus Management](https://developer.amazon.com/docs/vega/0.23/focus-management.html).

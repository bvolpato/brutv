# BruTV - State-of-the-Art IPTV & Live Stream Player

BruTV is a native IPTV player for Apple and Android devices. The SwiftUI app targets iPhone, iPad, and Mac Catalyst. The Kotlin app adapts to Android phones, tablets, Android TV, and Android-based Fire TV devices. Both use Xtream Codes, M3U sources, and compatible `brutv://login` QR links.

See [the Android guide](mobile/android/README.md) for builds, APK installation, TV pairing, and device compatibility.

The separate [Vega OS starter](mobile/vega/README.md) has source and JavaScript validation. It still requires Amazon SDK packaging and device validation.

The [PS5 homebrew port](mobile/ps5/README.md) is a native C++17/OpenGL application
with FFmpeg playback, DualSense controls, and a Linux desktop preview. It builds
as a ShadowMountPlus home-screen title. Physical PS5 playback validation is
required before calling it console-ready.

## Live pause and rewind

Supported HLS channels use a temporary recorder that keeps fetching completed video segments independently of the paused player. Rewind and forward move through the retained window; **Go Live** returns to the stream's normal live position and resumes playback. The recorder retains up to **10 minutes or 256 MiB**, whichever limit is reached first. High-bitrate channels can reach the storage limit sooner. The window is shown in the player, and an expired pause is explained rather than presented as a complete recording.

Temporary video stays on the device and is removed when playback closes or changes channels. Stale session files are cleaned on a subsequent start. This is a rolling buffer, not a recording library. Vega stores encoded segment files and counts their full encoded size against the same storage cap.

The first supported format is clear, muxed HLS. Unsupported encryption, separate renditions, byte-range playlists, and other formats fall back to ordinary playback with a timeshift availability message. No tracks are silently discarded to enable recording. See each platform guide for its exact supported formats and validation results.

Fetching continues during an in-app pause. Android and Vega clear the buffer when the player leaves the foreground, except Android Picture in Picture. iPhone and iPad can suspend an inactive or locked app, interrupting capture. Mac capture requires an active process. Resume, storage limits, and provider gaps must be tested on physical devices before release.

### Reproduce a pause longer than the provider window

With Node.js and FFmpeg available, run:

```sh
node tools/timeshift-fixture.mjs
```

Add `http://127.0.0.1:8765/playlist.m3u` on the same computer, or `http://10.0.2.2:8765/playlist.m3u` in an Android emulator. The source exposes only six seconds of HLS history and deletes older segments. Pause BruTV for at least 30 seconds, confirm downloads and temporary files continue growing, resume the saved video, rewind and forward, then return to live. The `/stats` endpoint counts downloads. Closing playback must remove the app's temporary session. Stop the fixture with Ctrl+C.

---

## Apple App Features

- **Real-Time Buffer Engine:**
  - Buffer-ahead preferences: **Ultra Low Latency (1.5s)**, **Balanced (4.0s)**, and **High Stability (10.0s)**. AVPlayer controls actual buffering and live timing; these preferences do not guarantee a fixed delay or uninterrupted playback.
  - **MPEG-TS Relay Engine:** Xtream live channels play through a local relay by default. The relay streams the provider continuous `.ts` feed, cuts segments at video keyframes, corrects parameter set ordering, and serves local low-latency HLS. If the relay cannot connect, playback falls back to the provider HLS stream.
  - **Live Edge Priority:** Live playback preserves its time offset from the live broadcast. After a stall, playback steps down variant quality and resumes buffered data immediately instead of freezing.
  - **Live Pause and Rewind:** Enabled by default for compatible live channels and configurable in Settings > Playback. Captures live video to a temporary circular disk buffer (up to 10 minutes or 256 MiB) for instant pause, seek, and rewind.
  - Automatic recovery for transient failures, with a watchdog timer and automatic retries.
  - In-player **Stream Telemetry HUD** displaying real-time buffer seconds ahead of playhead, observed network bitrate (Mbps), native resolution, frame rate, dropped frames, and stall counters.
- **Two Ways to Sign In:**
  - Xtream Codes: server URL, username, and password.
  - M3U playlist: paste the playlist URL. If the URL is an Xtream `get.php` link, BruTV signs in with the Xtream API instead, because it is much faster than a large playlist.
- **QR Code Sign-In:**
  - On the login screen, tap the camera button to scan a QR code with the device camera or select a screenshot from Photos.
  - Settings > **Share Sign-In QR Code** displays a QR code and a `brutv://login` link for the active source.
  - The **Paste** button on the login screen reads a copied `brutv://` link from the clipboard.
- **Channels First:**
  - Fast channel switching and swipe gestures to flip stations directly on the video canvas.
  - In-player **Channel Guide Drawer** overlay with logos to surf without exiting full screen.
  - **Mini Player:** Keep a live video thumbnail playing in the channel list while browsing other streams.
  - Categorized browsing (Globo Sudeste, SBT, Record, Band, News, Sports, Premiere, etc.).
  - Channel logos with high-performance memory and disk caching.
  - Quality badges automatically parsed from stream titles (4K, FHD, HD, SD).
  - Search and filter by quality or category.
  - Favorite channel bookmarking and watch history.
- **Movies (VOD) & Series:**
  - Catalog browsing with TMDb posters, ratings, plot overviews, director and cast details.
- **Designed for Apple TV, iPad, iPhone, and Mac:**
  - Native Apple TV (tvOS) target with Siri Remote focus engine, Play/Pause remote toggle, and up/down channel zapping.
  - Native tvOS Top Shelf extension showcasing favorites and continue-watching queues with instant deep linking.
  - Adaptive tab and sidebar navigation on iPhone, iPad, and Mac.
  - Native Picture-in-Picture (PiP) and background audio playback.
  - Local playback diagnostics in Settings, with startup, buffering, and recovery summaries that you can clear or share. No automatic diagnostics upload or analytics SDK.
  - On Mac Catalyst, double-click toggles full screen, and the Esc key exits full screen.
  - Dark glassmorphism Apple TV aesthetic across all screens.

---

## Project Structure

```
brutv/
├── build.sh                       # Convenience simulator build wrapper
├── test.sh                        # Test execution wrapper
├── release.sh                     # Release IPA export wrapper
├── capture-screenshots.sh         # App Store screenshots generator
├── PRIVACY.md                     # Privacy Policy
├── mobile/ios/
│   ├── STORE_LISTING.md           # App Store copy, keywords, categories, reviewer notes
│   ├── RELEASE.md                 # Full release instructions
│   ├── RELEASE_NOTES.md           # Version 1.0.0 release notes
│   └── BruTV/
│       ├── BruTV.xcodeproj        # Xcode project
│       ├── build.sh               # Local simulator build script
│       ├── test.sh                # Test runner
│       ├── release.sh             # App Store release & codesigning script
│       ├── capture-screenshots.sh # Automated screenshot capture script
│       ├── signing/               # Signing documentation & team settings
│       ├── BruTV/                 # App source code (SwiftUI, AVFoundation)
│       │   ├── BruTVApp.swift     # App entry point
│       │   ├── AppRootView.swift  # Root navigation router
│       │   ├── Models/            # Account, Channel, EPG, PlayerSettings models
│       │   ├── Services/          # XtreamCodesClient, HLSBufferEngine, PlaybackManager, Stores
│       │   ├── Views/             # LiveTVView, PlayerView, VODView, SeriesView, LoginView, etc.
│       │   └── Resources/         # AppIcon (all resolutions), Assets, PrivacyInfo.xcprivacy
│       ├── BruTVTests/            # Unit test suite
│       └── BruTVUITests/          # UI test suite
```

---

## Quick Start

### 1. Build for Simulator

Apple builds require Xcode 27.2 and the iOS 27.2 SDK or later. The minimum supported iOS version remains 17. Native tabs and sidebars adapt to available space and safe areas. iPhone Duo posture and resize behavior still require the Apple UI validation described below.

To build for iOS Simulator:

```bash
./build.sh
```

To build for Apple TV (tvOS) Simulator:

```bash
./build.sh --tvos
```

### 2. Run Tests

Run the full Apple unit and UI suite on a Mac with Xcode:

```bash
./test.sh
```

Run the portable source, library, and playback-policy tests on Linux or macOS with Swift installed, or through Docker:

```bash
./test.sh --core
```

The core suite compiles the shared Swift logic. AVPlayer, SwiftUI, account integration, and device playback still need the Xcode suite and device testing. See [the release guide](mobile/ios/RELEASE.md#2-running-automated-tests) for details.

### 3. Capture Screenshots

```bash
./capture-screenshots.sh
```

### 4. Build Signed App Store IPA

Put the `.p12` certificate and the App Store `.mobileprovision` in `mobile/ios/BruTV/signing/`. Git ignores both files.

```bash
IOS_P12_PASSWORD='<password>' ./release.sh --platform ios --skip-simulator-build
```

See [RELEASE.md](mobile/ios/RELEASE.md) for details.

---

## Make a Sign-In QR Code on a Laptop

The `tools/brutv-login-qr.py` script writes a PNG with a `brutv://login` QR code.

```bash
uv run tools/brutv-login-qr.py --server http://example.com:8080 --username USER --password PASS -o login.png
uv run tools/brutv-login-qr.py --m3u "https://example.com/playlist.m3u" -o login.png
```

> [!WARNING]
> The QR code and the link contain the password in plain text. Share them only with people you trust.

If BruTV is not installed, the `brutv://` link does nothing. The person must install BruTV first.

---

## Test data

Debug and UI test flows use synthetic local fixtures. They do not include a provider account or contact a subscription service. To test an authorized provider, supply its credentials locally through the opt-in integration-test environment described in the Apple release guide. Never commit account credentials or include them in screenshots.

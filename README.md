# BruTV - State-of-the-Art IPTV & Live Stream Player

BruTV is an IPTV player built natively with Swift and SwiftUI, specifically targeted for **iPadOS** and **iOS**. Engineered for real-time quality and low-latency buffering, BruTV features instant channel zapping, telemetry HUD, 4K/FHD stream playback, and Picture-in-Picture.

---

## Key Features

- **Real-Time Buffer Engine:**
  - Configurable buffer duration: **Ultra Low Latency (1.5s)** for near-live broadcast sports timing, **Balanced (4.0s)**, and **High Stability (10.0s)**.
  - Automatic stream recovery with a 10-second connection watchdog and up to 2 retries. Live channels always play as HLS (`.m3u8`).
  - In-player **Stream Telemetry HUD** displaying real-time buffer seconds ahead of playhead, observed network bitrate (Mbps), native resolution, frame rate, dropped frames, and stall counters.
- **Two Ways to Sign In:**
  - Xtream Codes: server URL, username, and password.
  - M3U playlist: paste the playlist URL. If the URL is an Xtream `get.php` link, BruTV signs in with the Xtream API instead, because it is much faster than a large playlist.
- **QR Code Sign-In:**
  - Settings > **Share Sign-In QR Code** shows a QR code and a `brutv://login` link for the current source.
  - Scan the code with the Camera app, or open the link, and BruTV signs in automatically.
  - On the login screen, the **Paste** button reads a copied `brutv://` link.
- **Channels First:**
  - Fast channel switching and swipe gestures to flip stations directly on the video canvas.
  - In-player **Channel Guide Drawer** overlay with logos to surf without exiting full screen.
  - Categorized browsing (Globo Sudeste, SBT, Record, Band, News, Sports, Premiere, etc.).
  - Channel logos with high-performance memory and disk caching.
  - Quality badges automatically parsed from stream titles (4K, FHD, HD, SD).
  - Search and filter by quality or category.
  - Favorite channel bookmarking and watch history.
- **Movies (VOD) & Series:**
  - Catalog browsing with TMDb posters, ratings, plot overviews, director and cast details.
- **Designed for iPad & iPhone:**
  - Multi-column `NavigationSplitView` sidebar on iPad taking advantage of large screens.
  - Native Picture-in-Picture (PiP) and background audio playback.
  - Dark glassmorphism Apple TV aesthetic.

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

```bash
./build.sh
```

### 2. Run Tests

```bash
./test.sh
```

### 3. Capture Screenshots

```bash
./capture-screenshots.sh
```

### 4. Build Signed App Store IPA

Put the `.p12` certificate and the App Store `.mobileprovision` in `mobile/ios/BruTV/signing/`. Git ignores both files.

```bash
IOS_P12_PASSWORD='<password>' ./release.sh --skip-simulator-build
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

## Test Credentials

Debug builds have a **"Fill Demo Credentials (virello.win)"** button on the login screen. UI tests use the same account:
- **Server:** `http://virello.win`
- **Username:** `Bruno081225p2`
- **Password:** `tv8392602653`

Release builds do not contain this account. The code is inside `#if DEBUG` blocks. App Review and store screenshots use the public playlist `https://iptv-org.github.io/iptv/countries/br.m3u`.

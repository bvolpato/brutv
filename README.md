# BruTV - State-of-the-Art IPTV & Live Stream Player

BruTV is an IPTV player built natively with Swift and SwiftUI, specifically targeted for **iPadOS** and **iOS**. Engineered for real-time quality and low-latency buffering, BruTV features instant channel zapping, telemetry HUD, 4K/FHD stream playback, and Picture-in-Picture.

---

## Key Features

- **Real-Time Buffer Engine:**
  - Configurable buffer duration: **Ultra Low Latency (1.5s)** for near-live broadcast sports timing, **Balanced (4.0s)**, and **High Stability (10.0s)**.
  - Automatic stream recovery with intelligent protocol fallback (HLS `.m3u8` to MPEG-TS `.ts`).
  - In-player **Stream Telemetry HUD** displaying real-time buffer seconds ahead of playhead, observed network bitrate (Mbps), native resolution, frame rate, dropped frames, and stall counters.
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

```bash
export IOS_TEAM_ID="83BXSDT7QC"
export IOS_PROFILE_NAME="BruTV AppStore Distribution"
export IOS_P12_PASSWORD="<password>"
export IOS_CERTIFICATE_PATH="$PWD/signing/ios_distribution.p12"
export IOS_PROVISIONING_PROFILE_PATH="$PWD/signing/BruTV_App_Store_Distribution.mobileprovision"

./release.sh
```

---

## Test Credentials

For quick testing, a demo server account is pre-configured:
- **Server:** `http://example.invalid`
- **Username:** `REDACTED_USERNAMEp2`
- **Password:** `REDACTED_PASSWORD`
Tap **"Fill Demo Credentials (example.invalid)"** on the login screen to connect instantly.

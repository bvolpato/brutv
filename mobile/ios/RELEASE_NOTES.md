# BruTV Release Notes

## Version 1.0.0 (Build 1) - Initial Release

BruTV is an IPTV streaming player designed for iPadOS and iOS, built with a focus on real-time stream quality and low-latency buffering.

### Key Highlights:

- **State-of-the-Art Buffering Engine:**
  - Ultra Low Latency Profile (1.5s forward buffer) tailored for live sports.
  - Balanced Profile (4.0s forward buffer) for consistent broadband playback.
  - High Stability Profile (10.0s forward buffer) for fluctuating cellular networks.
  - Automatic stream recovery with a connection watchdog and automatic retries.

- **Instant Channel Zapping:**
  - Swipe gestures on the player to switch between channels without delay.
  - In-player Channel Guide Drawer with channel logos to flip stations while watching.

- **Real-Time Stream Telemetry HUD:**
  - Live buffer health monitor (seconds ahead of playhead).
  - Observed network throughput (Mbps / kbps).
  - Video resolution, frame rate, dropped frame counter, and stall diagnostics.

- **Designed for iPad, iPhone & Mac:**
  - Native iPad `NavigationSplitView` sidebar layout taking advantage of large screens.
  - Picture-in-Picture (PiP) multitasking and background audio support.
  - Dark mode glassmorphic UI.

- **Live Channels with Logos & Quality Badges:**
  - High-resolution channel logos with memory and disk caching.
  - Dynamic stream quality detection (4K, FHD 1080p, HD 720p, SD).
  - Instant category filtering (Globo Sudeste, SBT, Record, Band, News, Sports, Premiere).
  - Instant real-time channel search.

- **Full Xtream Codes API Compatibility:**
  - Live TV, Movies (VOD), and TV Series catalogs with TMDb artwork and ratings.
  - Multi-account / server profile switching.
  - Pre-configured demo login for rapid testing.

- **M3U Playlists and QR Code Sign-In:**
  - Sign in with an M3U playlist URL. M3U sources show live channels only.
  - Share a sign-in QR code from Settings. Scanning it opens BruTV and signs in automatically.

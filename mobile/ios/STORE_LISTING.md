# App Store Listing Metadata - BruTV

This document contains the copy, keywords, categories, URLs, and reviewer notes for the BruTV App Store submission.

---

## App Store Product Info

### App Title (Max 30 characters)
`BruTV - IPTV Player & Streams`

### Subtitle (Max 30 characters)
`IPTV that just works`

### Promotional Text (Max 170 characters)
`A fast, free IPTV player for iPhone, iPad, and Mac. Low-latency buffering, instant channel zapping, Picture-in-Picture, and QR code sign-in for the whole family.`

### Price
Free. No in-app purchases, no ads, no tracking.

---

## App Description (Max 4,000 characters)

BruTV is a free IPTV player for iPhone, iPad, and Mac. It is built for live channels: they start fast, stay in sync with the broadcast, and keep playing when the network changes.

BruTV does not include any channels, video content, or subscriptions. To watch, connect the Xtream Codes account or M3U playlist that your TV provider gives you. Only connect to services that you are authorized to use.

### Key Features

- **Low-Latency Buffering:**
  - **Ultra Low Latency (1.5s buffer):** keeps live sports and news close to real time.
  - **Balanced (4.0s buffer):** the default. Fast channel changes with protection against network jitter.
  - **High Stability (10.0s buffer):** a deeper buffer for weak or cellular connections.
  - Automatic stream recovery when a connection stalls.

- **Instant Channel Zapping:**
  - Swipe left or right on the video to change channels.
  - The in-player channel guide shows logos while the stream keeps playing.

- **Stream Telemetry HUD:**
  - See the buffer ahead of the playhead, network bitrate, resolution, frame rate, dropped frames, and stalls.

- **Designed for iPhone, iPad, and Mac:**
  - Sidebar layout on iPad and Mac. Tab bar on iPhone.
  - Picture-in-Picture and background audio.
  - Keyboard shortcuts on Mac and iPad.

- **Channel Browsing:**
  - Channel logos with memory and disk caching.
  - Quality badges read from stream names (4K, FHD, HD, SD).
  - Filter by your provider's categories and search by name.
  - Favorites and watch history.

- **Movies and Series:**
  - Browse your provider's on-demand catalog with posters, ratings, and episode lists (Xtream Codes accounts).

- **Two Ways to Sign In:**
  - Xtream Codes: server, username, and password.
  - M3U playlist: paste the playlist URL.
  - Save several profiles and switch between them.

- **QR Code Sign-In:**
  - Share your sign-in as a QR code from Settings. Family members scan it with the Camera, and BruTV signs in automatically. Nobody has to type a server, username, or password.

---

## Metadata & Keywords

### Keywords (Max 100 characters, comma-separated)
`iptv,player,live tv,m3u,m3u8,hls,xtream,playlist,channels,streaming,pip,epg,tv player,qr`

> [!NOTE]
> The keywords contain no channel or broadcaster names. Apple can reject third-party trademarks in keywords (guideline 2.3.7).

### Categories
- **Primary:** `Entertainment`
- **Secondary:** `Utilities`

### Age Rating
Answer "None" to all content questions. BruTV ships with no content. Apple may still ask about unrestricted web access. Answer "No", because BruTV has no web browser.

### App URLs
- **Support URL:** `https://brunovolpato.com/brutv/`
- **Marketing URL:** `https://brunovolpato.com/brutv/`
- **Privacy Policy URL:** `https://brunovolpato.com/brutv/privacy/`

### App Privacy (Nutrition Label)
Data Not Collected. BruTV has no backend, analytics, or ads. Credentials stay on the device.

### Copyright
`2026 Bruno Volpato`

---

## Screenshots

Upload these files in this order. They are at native resolution, so App Store Connect accepts them as they are. To make them again, run `mobile/ios/BruTV/capture-screenshots.sh`.

| App Store Connect slot | Folder | Size |
| --- | --- | --- |
| iPhone 6.9" Display | `mobile/ios/BruTV/screenshots/iphone-6.9-inch/` | 1320 x 2868 |
| iPad 13" Display | `mobile/ios/BruTV/screenshots/ipad-13-inch/` | 2064 x 2752 |

Order: `02_channels`, `03_player`, `04_guide`, `05_settings`, `01_login`. The images use the public iptv-org playlist and the Education category, so they show no private account and no commercial channel brands.

---

## Notes for App Review

Paste this text into App Store Connect > App Review Information > Notes. Leave "Sign-in required" unchecked, because the reviewer can use the public playlist below with no account.

```
BruTV is a player only. It ships with no channels, content, or accounts. Users connect the Xtream Codes account or M3U playlist that their own provider gives them.

To test without an account, use a public, legal playlist of free-to-air channels from the iptv-org project (https://github.com/iptv-org/iptv):

1. Launch BruTV.
2. Select "M3U Playlist".
3. Enter: https://iptv-org.github.io/iptv/countries/br.m3u
4. Tap "Load Playlist". About 400 channels load in a few seconds.
5. Tap any channel to play it. Use the "Channels" button, Close, Minimize, or swipe down to go back.

QR code sign-in: Settings > Share Sign-In QR Code. Scanning the code with the Camera opens a brutv://login link, and BruTV signs in automatically.

Some public channels can be offline at any time. If one does not play, try another.

The app does not track users, show ads, or collect data. Credentials and favorites stay on the device.
```

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

- **Low-Latency Buffering & MPEG-TS Relay:**
  - **MPEG-TS Relay:** Xtream channels play through a local relay that reads continuous `.ts` streams, cuts at keyframes, and falls back to HLS automatically.
  - **Live Edge Priority:** Keeps playback at the live edge after stalls, stepping down bitrate when needed.
  - **Ultra Low Latency (1.5s buffer):** keeps live sports and news close to real time.
  - **Balanced (4.0s buffer):** the default. Fast channel changes with protection against network jitter.
  - **High Stability (10.0s buffer):** a deeper buffer for weak or cellular connections.
  - Automatic stream recovery when a connection stalls.

- **Instant Channel Zapping:**
  - Swipe left or right on the video to change channels.
  - The in-player channel guide shows logos while the stream keeps playing.
  - The mini player keeps live video playing while you browse the channel list.

- **Stream Telemetry HUD:**
  - See the buffer ahead of the playhead, network bitrate, resolution, frame rate, dropped frames, and stalls.

- **Designed for iPhone, iPad, and Mac:**
  - Sidebar layout on iPad and Mac. Tab bar on iPhone.
  - Picture-in-Picture and background audio.
  - Double-click to toggle full screen on Mac, and press Esc to exit full screen.
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
  - Tap the camera icon on the login screen to scan a QR code with the device camera or select a QR image from Photos.
  - Share your sign-in as a QR code from Settings. Family members can scan it to sign in without typing passwords.

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
4. Tap "Load Playlist" and wait for the channels to load.
5. Tap any channel to play it. Use the "Channels" button, Close, Minimize, or swipe down to go back.

QR code sign-in: Settings > Share Sign-In QR Code displays a sign-in QR code. Scanning the code with the Camera app opens a brutv://login link, and BruTV signs in automatically. Users can also tap the camera button on the login screen to scan a code directly in the app or choose a QR screenshot from Photos.

Some public channels can be offline at any time. If one does not play, try another.

The app does not track users, show ads, or collect data. Credentials and favorites stay on the device.
```

### Additional macOS review notes

Append this explanation to the macOS version's App Review Information > Notes. Also add `com.apple.security.network.server` under App Sandbox Information and describe the same loopback playback use. Keep the entitlement enabled: the sandboxed Catalyst app needs it for its local playback server.

```
macOS sandbox entitlements (Guideline 2.4.5):

com.apple.security.network.server is required for an embedded, temporary HTTP server used by Pause & Rewind Live TV and the MPEG-TS-to-HLS playback relay. BruTV buffers live media locally and AVPlayer reads its HLS playlist and segments through this server. NWListener is explicitly bound to IPv4 loopback (127.0.0.1) on an ephemeral port, with a per-session token in the URL. It does not listen on the LAN or Internet. The server stops when playback closes or the channel changes. This is on-device playback functionality, not hosting for other devices.

com.apple.security.network.client is used for outgoing requests to download the user-selected provider playlist and media streams, and for AVPlayer to read the local playback server.

To exercise the local server without an account:
1. Select M3U Playlist on the sign-in screen, enter https://iptv-org.github.io/iptv/countries/br.m3u, and click Load Playlist.
2. Open Settings in the navigation rail. Under LIVE REWIND, enable Pause & Rewind Live TV (enabled by default).
3. Select Live TV and play a live HLS channel, for example +MaisUm (720p), currently listed in that playlist. Allow initial buffering and let playback run for at least 30 seconds.
4. In the player, use Rewind 10 seconds or the Live rewind position slider, then pause and resume. AVPlayer is reading the locally buffered media through the loopback HTTP server. The controls become available once enough media has accumulated.

Public streams can change or go offline. If needed, try another live HLS channel. No credentials are needed for this review path.
```

The HLS rewind buffer supports unencrypted MPEG-TS segments. A channel with separate audio tracks, fragmented MP4 segments, encryption, or byte ranges can fall back to direct playback and will not demonstrate the local server. Verify the example channel's playlist before each submission. The example above was checked on 2026-10-16; its manifest contained live `.ts` segments without the unsupported tags.

# BruTV for Android

IPTV that just works. One native Kotlin app adapts to Android phones, tablets,
Android TV, Google TV, and Android-based Fire TV devices. It includes no provider
account or channel package. Add a source you have permission to use.

## Build and install

Open this directory in Android Studio, or use JDK 17 or later with the Android
SDK and the checked-in Gradle wrapper:

```bash
export ANDROID_HOME="$HOME/android-sdk" # Use your Android SDK directory.
./gradlew :app:assembleDebug :app:assemblePreview
./test.sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Android Studio can create an ignored `local.properties` with `sdk.dir` instead
of the environment variable. The project compiles with SDK 37 and targets SDK
36. The minimum runtime is Android 6 / API 23. Java, Kotlin, Compose, and Media3
versions are pinned in the Gradle files.

The debug APK is signed with the local Android debug key. An optimized family
preview uses the same development key and is available at
`app/build/outputs/apk/preview/app-preview.apk`. It includes release shrinking
without a production signing key. Release package tasks require the production
signing configuration described below. `./build.sh` also builds release
packages, so configure signing before using it. Do not distribute a debug or
preview build as a store release.

A different computer normally has a different debug key. An installed preview
cannot update to an APK signed by another key. Keep a consistent testing key,
or use a separate device for production builds. Uninstalling removes saved
profiles.

## Production release signing

Keep the upload keystore and its Gradle properties outside Git. By default,
Gradle reads `~/.config/brutv/android/keystore.properties`; set
`BRUTV_ANDROID_SIGNING_PROPERTIES` to use a different properties file. The file
must contain an absolute keystore path and all four properties:

```properties
storeFile=/absolute/path/to/release.jks
storePassword=stored-locally
keyAlias=brutv-upload
keyPassword=stored-locally
```

Restrict access to the directory, properties file, and keystore. Back up the
keystore securely and retain it for every future update. Losing or replacing it
can prevent direct APK updates and may block store submissions. Never commit
the keystore or its passwords. Release package tasks fail when the properties
or keystore are missing.

Build and verify a signed APK and App Bundle with:

```bash
./release.sh
```

The script verifies both signatures and copies versioned artifacts into
`build/distributions/`. The APK and AAB are also left in Gradle's release output
directories. Google Play may require the configured upload certificate to
match the app's existing Play Console setup.

For family testing on Android/Fire OS, Downloader can download an APK from a
direct HTTPS URL and open the system installer. The APK must first be hosted
at an accessible URL; building locally does not publish it. Allow installation
from Downloader in the device's settings when installing. Android TV can also
install through `adb install`. Store submission and public APK hosting are
separate from this bootstrap.

## Sources and sign-in

- Xtream Codes uses the same server, username, password, player API, and stream
  paths as the iOS app. Xtream `get.php` playlist links use the richer API.
- Remote M3U playlists and imported local `.m3u` files support channel groups,
  names, logos, and quality filters. HTTP stream headers from supported playlist
  directives travel with the stream. A local file stays on its importing device.
- The scanner reads the iOS app's `brutv://login` QR codes, including percent
  encoded credentials and nested M3U URLs. Links can also be opened or pasted.
- Phones and tablets request camera permission only when scanning. Camera
  hardware and Google Play Services are not required to install the app.
- TVs offer manual sign-in and **Pair with phone**. Scan the TV code in BruTV
  on an Android phone, choose a saved URL/Xtream source, and send it. Both devices
  must be on a local Wi-Fi network that permits communication between clients.

TV pairing uses an ephemeral RSA key and an AES-GCM encrypted credential
envelope. Its local receiver runs only while pairing is open, expires after
three minutes, and accepts a single transfer. This Android companion protocol
is additional to the existing iOS sign-in links; the iOS app does not yet send
TV pairing requests. Device-local M3U files cannot be transferred this way.

Shared **sign-in** QR codes still contain source credentials, like iOS. Only
show them to people you trust. Sensitive QR screens prevent screenshots.
Saved profiles, favorites, recent channels, settings, and VOD positions are
encrypted with Android Keystore and excluded from backup. Libraries are scoped
to the source so identical channel IDs from different providers do not collide.
Imported playlist files are copied into the app's private no-backup directory;
the playlist file itself is not encrypted. Removing its profile deletes that
copy.

## Browsing and playback

Live TV, movies, series, favorites, and settings have touch and remote controls.
TVs use a large navigation rail and visible focus; phones use bottom navigation,
and tablets use a wider grid. Catalogs load on demand. Grids are lazy, images
are cached, and search/filter work happens off the main thread. Xtream sources
can provide short EPG schedules and series episodes in addition to the iOS
catalog features.

Media3 uses platform decoders, decoder fallback, audio focus, adaptive bitrate
where an HLS/DASH source supplies variants, and bounded buffers. Balanced and
stability preserve the stream's native live timing; stability keeps a deeper
buffer. Ultra low latency explicitly targets a shorter live delay and can
rebuffer more on conventional HLS streams. Playback includes seeking and resume
for VOD, a channel guide, track selection, live-edge recovery, and optional
measured telemetry.
Recovery is capped and cancelled when switching, pausing, or closing. Live video
is not cached to disk. Picture-in-Picture is available on supported devices.

A fixed-bitrate stream cannot adapt to a slower connection, and a broken
provider or unsupported hardware codec can still fail. 4K/HDR, camera capture,
low-memory sticks, and Wi-Fi pairing need physical device testing before a
family/store release.

## Validation performed

Debug, optimized preview, unsigned release APK, and unsigned release App Bundle
builds pass, along with unit tests and lint for all three build types. Lint
reports no errors, with nonfatal warnings for compatibility and style. The
preview APK's development signature verifies. Android API 36 instrumentation
also passed real Keystore encryption/tamper checks and the local pairing
socket/cryptography exchange.

Phone and Android TV emulators exercised sign-in, catalogs, remote focus and
keyboard navigation, HLS/MP4 playback, media pause, series episodes, M3U import,
and saved-profile restoration. A tablet-sized viewport exercised the wider
layout. A controlled stream fixture verified bounded recovery and cancellation
when switching channels. These checks do not establish physical tablet, Fire
TV, camera, or Wi-Fi pairing performance.

With the owner's existing Example provider account, the native Android app authenticated
and displayed 1,604 live channels, 18,770 movies, and 9,070 series on October 12,
2026. Real TV Cultura FHD playback rendered 1920 x 1080 video. Its conventional
HLS playlist used approximately 10-second segments with an 11-second target
duration. That exposed the previous 4-second balanced live offset, which was
removed so normal profiles preserve Media3/provider live timing. Provider
credentials were not added to this target or its APK.

The balanced profile's original sample recorded four buffering transitions in
123 seconds. After the timing change, a 249-second sample recorded two, with no
retries or dropped frames. These were sequential samples of a changing live
source on an emulator, not a controlled performance benchmark or proof of
buffer-free playback. The telemetry counter tracks READY-to-BUFFERING
transitions after playback begins; it does not classify their cause.

With native live timing and high stability selected, the same 1080p stream ran
for 251 seconds with zero reported buffering transitions, retries, or dropped
frames; the final buffered duration was 25.5 seconds. The previous high-stability
sample, with a forced 10-second live offset, recorded four buffering transitions
in 239 seconds. Try **High stability** for this Example provider stream. This remains a
short emulator sample; longer sessions and physical-device measurements are
required before promising consistent family-device performance.

Public APK hosting and store submission are separate from this local build. The
build outputs are local artifacts; no CI or deployment result is implied.

## Fire TV scope

The minimum API supports Fire OS 6 and later. Old Fire OS 5 / API 22 sticks are
outside this build. Amazon's Vega OS is a different platform and cannot run an
Android APK, including one downloaded with Downloader. A Vega app requires its
own SDK, package, and validation.

Primary references:

- [Media3 formats and decoder support](https://developer.android.com/media/media3/exoplayer/supported-formats)
- [Media3 1.11.1 HLS live timing](https://github.com/androidx/media/blob/1.11.1/libraries/exoplayer_hls/src/main/java/androidx/media3/exoplayer/hls/HlsMediaSource.java)
- [Android TV manifest requirements](https://developer.android.com/training/tv/get-started/create)
- [Fire TV OS/API versions](https://developer.amazon.com/docs/fire-tv/fire-os-overview.html)
- [Downloader](https://play.google.com/store/apps/details?id=com.esaba.downloader)

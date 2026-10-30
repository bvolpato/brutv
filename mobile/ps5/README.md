# BruTV for PS5

Native C++17/OpenGL homebrew IPTV player, with a Linux desktop build of the same
catalog, interface, and FFmpeg playback engine. The PS5 target is a ShadowMountPlus
directory title, not a retail PKG or a headless ELF payload.

The implementation supports:

- M3U playlists and Xtream Codes accounts, including compatible BruTV sign-in links.
- Live channels, categories, search, favorites, recent items, movies, series, and episodes.
- Xtream current programme information when the source provides it.
- Controller source entry with an on-screen keyboard and masked passwords.
- Provider channel logos and movie/series artwork loaded in the background.
- Vector navigation icons and PlayStation button symbols throughout the interface.
- HTTP(S), HLS, and local-file playback through FFmpeg software decoding.
- OpenGL video presentation and native PS5 stereo audio output at 48 kHz.
- Pause/resume, live rewind, VOD seeking, volume, bounded playback queues, and live reconnects.
- Selectable audio tracks and timed text subtitles, including SRT, WebVTT, and ASS text.

Sources, favorites, and recents stay in `/download0/brutv/settings.json` on the console.
This file contains source credentials. It is written atomically with mode `0600`;
keep it private. The app includes no account, channels, subscription, or analytics.
The native title reserves writable download data for these settings, without
requiring access outside its sandbox. Uninstalling the title may remove that data.

## Build and test on Linux

Ubuntu 24.04 / Linux Mint build dependencies:

```sh
sudo apt-get install build-essential cmake ninja-build pkg-config \
  libsdl2-dev libgl-dev libavformat-dev libavcodec-dev libavutil-dev \
  libswscale-dev libswresample-dev libcurl4-openssl-dev nlohmann-json3-dev \
  ffmpeg nodejs xvfb
./mobile/ps5/build.sh
./mobile/ps5/test.sh
./mobile/ps5/build/desktop/brutv
```

Tests generate short video/audio media and multi-track captions, decode and resample
them, switch audio and subtitles, and exercise pause/seek/stop. A paced loopback
HTTP stream verifies continued recording during pause, rewind, and Go Live. MP4
byte ranges and HLS segments also use a loopback server. Catalog tests cover provider responses, login links, and source-scoped
settings. They require no private provider account.
Artwork checks cover image decoding, input and memory limits, background requests,
failed-image caching, and eviction when browsing between pages.

For a public M3U catalog:

```sh
./mobile/ps5/build/desktop/brutv \
  --source 'https://iptv-org.github.io/iptv/countries/br.m3u'
```

`--source` also accepts a BruTV sign-in link. Avoid putting credential-bearing
links into shell history; use the app's Settings screen instead.

A synthetic, clearly labeled UI preview is available with `--preview`. Its sample
cards do not play streams. Real decoding can be checked separately with
`--play /path/to/video.mp4`. For a headless render:

```sh
xvfb-run -a env SDL_AUDIODRIVER=dummy LIBGL_ALWAYS_SOFTWARE=1 \
  ./mobile/ps5/build/desktop/brutv --preview --frames 60 \
  --screenshot /tmp/brutv-ps5-preview.png
```

## Build a PS5 home-screen title

In addition to the host tools above, install `clang-18 lld-18 llvm-18 curl jq
unzip zip`. Run:

```sh
./mobile/ps5/tools/build-ps5.sh
```

The bootstrap downloads pinned public SDK, OpenGL, PacBrew, and native-title tools
into `~/.cache/brutv-ps5`, verifies archive SHA-256 values, and builds the native
runtime. `BRUTV_PS5_CACHE` overrides that cache. No proprietary Sony SDK, keys,
firmware files, or exploit payloads are included.

Outputs:

```text
mobile/ps5/build/ps5/title/PPSA99241/
  eboot.bin
  sce_sys/param.json
  sce_sys/icon0.png
  sce_module/libc.prx
  assets/
  licenses/
  build-provenance.json
mobile/ps5/build/ps5/PPSA99241.zip
mobile/ps5/build/ps5/SHA256SUMS
```

`PPSA99241` is a local development title ID. Check for a collision before copying
it to a console. Build provenance records exact upstream pins and explicitly
records that a local build is not proof of a successful console test.

The intended test console uses firmware 13.42, etaHEN 2.5B with kstuff-lite 1.11,
and ShadowMountPlus 1.7. Launch the app from the home screen as a signed-in console
user. Payload Manager/elfldr is not the display or audio host for this app.
The project's source SDKs document broader firmware compatibility; BruTV itself
needs an actual test on each console configuration.

When the console's current IP is known, use FTP port 2121 to copy the title folder
to `/data/homebrew/PPSA99241`, then refresh/restart ShadowMountPlus as required by
your existing setup. See `tools/deploy-ps5.sh --help` for the checked FTP transfer
helper. The helper does not install or change a jailbreak and refuses to overwrite
an existing title. It does not use port 9021.

## Controls

| DualSense | Action |
| --- | --- |
| D-pad / left stick | Move focus, select a category or media item |
| Cross | Select; pause/resume in the player |
| Circle | Back; close playback |
| Square | Toggle a favorite |
| Triangle | Search; Go Live in the live player |
| L1 / R1 | Previous / next sidebar tab; cycle audio / subtitle tracks in the player |
| L2 / R2 | Seek backward / forward in VOD or the retained live window |
| Options | Settings; toggle playback controls in the player |

The desktop equivalents are arrows, Enter, Escape, F2, F3, Shift+Tab / Tab,
Page Up / Page Down, and F4. A desktop keyboard can type directly into an active
input field. The console keyboard includes case switching and URL punctuation.

## Playback limits and validation

Decoding is software-based, with two decoder threads and a bounded frame queue.
The initial display conversion is capped at 720p to keep CPU/memory use predictable;
source dimensions are validated up to 4K. That is not a promise of real-time 4K
decode. Codec, bitrate, stream, and firmware performance need console measurements.
There is no proprietary hardware-decoder integration, DRM playback, or PSN support.

Live playback retains demuxed, encoded media in private temporary files independently
of paused decoding. The rolling window retains at most ten minutes or 256 MiB of
serialized packets, whichever limit is reached first. The player shows the saved
window, storage use, and distance behind live. Rewind and forward stay inside that
window; Go Live resumes near the latest captured point. Expired pauses move to the
earliest retained video keyframe with an explanation. All captured audio and subtitle
packets retain their decoder metadata. Files contain no provider addresses, are
unlinked immediately after creation, and are released on stop, source change, or
process exit. Console storage uses the title's `/download0/brutv` sandbox.

Recording needs usable video keyframes and writable temporary storage. Storage
failure or a source that supplies no recordable keyframes falls back to direct
playback with an explanation. This packet recorder supports the clear formats that
the FFmpeg reader can demux; it does not add DRM support or background recording.
Decoder, network, disk performance, pause expiry, and stream discontinuities still
need physical-console measurements.

L1 cycles supported audio tracks. R1 cycles text subtitles and Off. Captions are
rendered as readable plain text, with up to three wrapped lines; ASS styling and
positioning are not preserved. Bitmap subtitles are not offered as selectable
tracks. IPTV availability depends on the user's authorized source.

Artwork uses the image URLs supplied by the provider. Only visible items are
requested, with two background workers, bounded queues, and cached failures. PNG,
JPEG, and other stb-supported bitmap formats are decoded to at most 512 pixels per
edge. The decoded cache is limited to 12 MiB and GPU textures to 16 MiB. Missing,
unsupported, or unreachable artwork uses a media icon. SVG and WebP are not decoded.

Validation distinguishes the portable tests, desktop OpenGL rendering, native
cross-link/package inspection, and physical PS5 playback. A compiled `eboot.bin`
alone does not verify display, DualSense input, audio, DNS/TLS, or streaming on a
console. The current PS5 IP must be confirmed before deployment and that final
test.

## Upstream work and licensing

Inspired by [PS5LM](https://github.com/cobanov/PS5LM). Its public native-title path,
[ps5-opengl](https://github.com/blackbearreloaded/ps5-opengl),
[ps5-native-app-boilerplate](https://github.com/blackbearreloaded/ps5-native-app-boilerplate),
the [PS5 Payload SDK](https://github.com/ps5-payload-dev/sdk), and
[PacBrew](https://github.com/ps5-payload-dev/pacbrew-repo) make this port possible.

This standalone port and its linked GPL dependencies are distributed under
GPL-3.0-or-later. See [LICENSE](LICENSE),
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and the bundled font and stb
notices. This does not change the licensing of the other BruTV platforms.

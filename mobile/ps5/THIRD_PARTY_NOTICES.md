# BruTV for PlayStation 5

The new `mobile/ps5` application is GPL-3.0-or-later. Its license does not change
any other BruTV platform. It includes no Sony SDK, console keys, proprietary
runtime module, channel subscription, or private IPTV credentials.

## Native application tooling and runtime

- [ps5-native-app-boilerplate](https://github.com/blackbearreloaded/ps5-native-app-boilerplate),
  BlackBearReloaded, GPL-3.0-or-later, pinned commit
  `44ae1dab529654eac795d2a7c4f5a0425102b8d7`.
  Startup, allocation bridge, intermediate linker layout, executable converter,
  FSELF writer, clean-room runtime emitter, and console networking compatibility
  are built from its source. `cmake/ps5-pie.ld` derives from its linker layout.
  The generated `libc.prx` SHA-256 is
  `e6ff45d16adf687855cc3b33b0c8a4132b6504360b221e0a34c7e99fb3ba0036`.
  Its compatibility runtime is not a complete ISO C/POSIX implementation.
- [PS5 payload SDK](https://github.com/ps5-payload-dev/sdk), version 0.43,
  John Törnblom and contributors. The SDK contains independently licensed
  components, including FreeBSD headers, LLVM libc++, libc++abi, libunwind, and
  public reverse-engineered import definitions. Preserve the SDK's license and
  source notices when redistributing those components.
- [ps5-homebrew-ui](https://github.com/blackbearreloaded/ps5-homebrew-ui),
  BlackBearReloaded, GPL-3.0-or-later, commit
  `bf44d80384d5b8f8f4f213cf98d748887211328d`, supplies reference facts for the
  ScePad sample layout, SceAudioOut setup, and EGL startup order. BruTV's audio
  ring and input implementation are new code.
- [ProsperoLight](https://github.com/blackbearreloaded/ProsperoLight),
  BlackBearReloaded, GPL-3.0-or-later, documents the `kern.rng_pseudo` kernel
  entropy mechanism used for checked 64-byte random reads. An unavailable
  entropy service causes an explicit failure, never a weak random fallback.

## Graphics

[PS5 OpenGL](https://github.com/blackbearreloaded/ps5-opengl), version 1.0.0,
BlackBearReloaded, GPL-3.0-or-later, source commit
`dce74910af7f4274c48d05e0ae001b3038462588`. The package includes complete source
archives and licenses for its Mesa, OpenGNM, PSBC, Khronos, and other dependencies.
Its application heap helper is linked with its complete allocator wrapper set.
BruTV requests a 256 MiB application-owned heap through the helper's public weak
override. The helper can fall back to smaller mappings or the platform allocator;
this is an allocation preference, not a process memory limit or a console-tested
memory guarantee. Artwork caches and decode dimensions remain bounded separately.
The `.so` import stubs declare system imports; they are not runtime Sony
implementations and are not copied into the title. Preserve the package's
`THIRD_PARTY_NOTICES.md`, `LICENSES/`, `provenance.json`, and `sources/` for binary
redistribution. The pinned graphics SDK describes its binary as host checked,
without console validation. BruTV does not claim otherwise.

## Media and HTTP

[PacBrew ports](https://github.com/ps5-payload-dev/pacbrew-repo), release 0.40.3,
provide FFmpeg 7 libraries, libcurl, OpenSSL, x264, zlib, zstd, libpsl, libiconv,
liblzma, and bzip2. FFmpeg and x264 make this linked application GPL compatible.
Other libraries retain their upstream licenses. The title packages the public CA
bundle from this release for HTTPS certificate validation. HTTP(S), HLS,
MPEG-TS, and supported file formats use real FFmpeg software decoding. There is
no hardware video-decoding claim. The native resolver supports IPv4; HTTP/3,
external processes, and POSIX user-database integration are not implemented.
The libc++ adapters expose only the C locale. UTF-8 title text is rendered
directly by the application. Calendar formatting uses UTC.

Release archive:
https://github.com/ps5-payload-dev/pacbrew-repo/releases/tag/v0.40.3

Build recipes and corresponding sources are available through the PacBrew
repository and the referenced upstream projects. Before distributing binaries,
provide the complete corresponding source and build inputs required by the
applicable GPL/LGPL licenses. A download link alone does not substitute for the
source obligations of the chosen distribution method.

## Portable application assets

- [nlohmann/json](https://github.com/nlohmann/json), version 3.11.3,
  Niels Lohmann and contributors, MIT license.
- [stb](https://github.com/nothings/stb), Sean Barrett and contributors,
  public domain or MIT license. `stb_image.h` decodes provider logos and posters,
  `stb_truetype.h` renders fonts, and `stb_image_write.h` writes preview captures.
  The vendored headers retain their license text.
- DejaVu Sans font, DejaVu/Bitstream license, included with its license in assets.
- BruTV's existing icon is reused as the application icon.

## Inspiration

[cobanov/PS5LM](https://github.com/cobanov/PS5LM) demonstrated the native PS5
application approach that inspired this port. BruTV's catalog, UI, rendering,
playback, and bounded audio queue are implemented for this repository.

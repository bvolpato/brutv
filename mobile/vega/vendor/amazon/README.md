# Amazon source provenance

`LICENSE` and `LICENSE-THIRD-PARTY` are copied unchanged from [Amazon's Vega Video Sample v0.23.0](https://github.com/AmazonAppDev/vega-video-sample/tree/20e2ac87e7f883413c6d05fa34c4be9f2a05a87d). They retain its MIT-0 template/sample license and Apache-2.0 Shaka notice.

`shaka-rel-v4.8.5-r1.7.tar.gz` and `polyfills/*.ts` come from the [official Amazon Shaka integration guide](https://developer.amazon.com/docs/vega/0.23/media-player-shaka-player.html), retrieved from:

https://amzndevresources.com/vega/media-player/shaka-rel-v4.8.5-r1.7-devices_scope.tar.gz

Archive SHA-256: `8a9d55c8bb9fdf08b40f46a308e47d6530cc31a251e381086434d77da17ff90f`.

The archive and original copyright/license headers are retained. Two vendor polyfills have `@ts-nocheck` added, matching the official sample build's treatment of browser-global declarations. The archive's Amazon polyfills retain headers referencing Amazon's accompanying license terms; the public archive does not contain a `LICENSE.TXT`. The sample's MIT-0 license is not represented here as an override for those separately downloaded materials. Confirm the applicable Vega SDK/download license terms before redistributing a release package.

The build helper applies the archive's patches to upstream [Shaka v4.8.5](https://github.com/shaka-project/shaka-player/tree/v4.8.5), commit `9ef114308b71e304327540f138de36f46f4a8f39`. Generated output is ignored and carries its Apache-2.0 license into `src/media/shaka/`.

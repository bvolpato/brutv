import {VideoPlayer} from '@amazon-devices/react-native-w3cmedia';
import Document from '../../vendor/amazon/polyfills/DocumentPolyfill';
import Element from '../../vendor/amazon/polyfills/ElementPolyfill';
import TextDecoderPolyfill from '../../vendor/amazon/polyfills/TextDecoderPolyfill';
import DOMParserPolyfill from '../../vendor/amazon/polyfills/DOMParserPolyfill';
import MiscPolyfill from '../../vendor/amazon/polyfills/MiscPolyfill';
import W3CMediaPolyfill from '../../vendor/amazon/polyfills/W3CMediaPolyfill';
import {httpURL} from '../domain/login';
import {MediaAdapter} from './PlaybackSession';

const shakaRuntime: typeof shaka = require('./shaka/shaka-player.compiled');

export function vegaAdapter(video: VideoPlayer, onError: () => void): MediaAdapter {
  Document.install();
  Element.install();
  TextDecoderPolyfill.install();
  W3CMediaPolyfill.install();
  MiscPolyfill.install();
  DOMParserPolyfill.install();
  global.gmedia = video;
  shakaRuntime.polyfill.installAll();
  // Amazon's patched fetch plugin avoids browser ReadableStream requirements.
  for (const scheme of ['http', 'https']) {
    shakaRuntime.net.NetworkingEngine.registerScheme(scheme, shakaRuntime.net.HttpFetchPlugin.parse,
      shakaRuntime.net.NetworkingEngine.PluginPriority.APPLICATION, true);
  }
  // Shaka's browser declarations expect DOM types; Vega implements the runtime W3C surface.
  const player = new shakaRuntime.Player(video as unknown as HTMLMediaElement);
  const handleError = (event: Event) => {
    const detail = (event as Event & {detail?: {severity: number}}).detail;
    if (detail?.severity === shakaRuntime.util.Error.Severity.CRITICAL) onError();
  };
  player.addEventListener('error', handleError);
  player.configure({
    abr: {enabled: true},
    streaming: {
      bufferingGoal: 20, rebufferingGoal: 3,
      retryParameters: {maxAttempts: 3, baseDelay: 1000, backoffFactor: 2, fuzzFactor: 0.5, timeout: 15000},
    },
    manifest: {retryParameters: {maxAttempts: 3, timeout: 15000}},
  });
  return {
    async load(url) {
      httpURL(url);
      const path = new URL(url).pathname.toLowerCase();
      if (path.endsWith('.ts') || path.endsWith('.mkv')) {
        throw new Error('Use HLS, DASH or an MP4 source on this Vega starter.');
      }
      await player.load(url);
    },
    async destroy() {
      player.removeEventListener('error', handleError);
      await player.destroy();
      if (global.gmedia === video) global.gmedia = null;
    },
  };
}

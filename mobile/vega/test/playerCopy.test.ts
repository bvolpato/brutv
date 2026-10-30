import assert from 'node:assert/strict';
import test from 'node:test';
import {localizePlayerMessage, playerText} from '../src/media/playerCopy';

test('Portuguese player copy covers all playback states and controls', () => {
  const text = playerText('pt');
  assert.equal(text.status.playing, 'Reproduzindo');
  assert.equal(text.status.error, 'Falha na reprodução. Confira o provedor e o formato da fonte e tente novamente.');
  assert.equal(text.back, 'Voltar ao catálogo');
  assert.equal(text.goLive, 'Voltar ao vivo');
  assert.match(text.recording(12, 4), /12 segundos salvos · 4 MB/);
  assert.match(text.behind(14), /14 segundos atrás da transmissão/);
});

test('Portuguese player translates the live rewind fallback and reconnect messages', () => {
  assert.equal(
    localizePlayerMessage('Encrypted streams play directly without local live rewind.', 'pt'),
    'Transmissões criptografadas são reproduzidas diretamente, sem voltar na transmissão.',
  );
  assert.equal(
    localizePlayerMessage('Reconnecting the live buffer. Saved content is still available.', 'pt'),
    'Reconectando o buffer temporário. O conteúdo salvo ainda está disponível.',
  );
  assert.equal(
    localizePlayerMessage('This HLS sequence is not supported for live rewind. Playing the provider directly without local rewind.', 'pt'),
    'Esta sequência HLS não permite voltar na transmissão. Reproduzindo diretamente do provedor.',
  );
  assert.equal(localizePlayerMessage(undefined, 'pt'), undefined);
});

test('English player copy preserves source error messages', () => {
  const message = 'Temporary storage is unavailable for live rewind.';
  assert.equal(localizePlayerMessage(message, 'en'), message);
});

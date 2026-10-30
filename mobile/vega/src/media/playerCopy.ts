import {PlaybackStatus} from './PlaybackSession';

export type PlayerLanguage = 'en' | 'pt';

const copy = {
  en: {
    status: {
      loading: 'Loading', buffering: 'Buffering', playing: 'Playing', paused: 'Paused', ended: 'Ended', error: 'Playback failed. Check the provider and source format, then retry.',
    } satisfies Record<PlaybackStatus, string>,
    back: 'Back to library', play: 'Play', pause: 'Pause', retry: 'Retry', back10: 'Back 10 seconds', forward10: 'Forward 10 seconds', goLive: 'Go live',
    expired: 'Your pause exceeded the saved window. Playback moved to the earliest saved point.',
    recording: (seconds: number, megabytes: number) => `Saving live TV in temporary storage · ${seconds} seconds saved · ${megabytes} MB`,
    checking: 'Checking live rewind support…', behind: (seconds: number) => `· ${seconds} seconds behind live`,
  },
  pt: {
    status: {
      loading: 'Carregando', buffering: 'Carregando o vídeo', playing: 'Reproduzindo', paused: 'Pausado', ended: 'Encerrado', error: 'Falha na reprodução. Confira o provedor e o formato da fonte e tente novamente.',
    } satisfies Record<PlaybackStatus, string>,
    back: 'Voltar ao catálogo', play: 'Reproduzir', pause: 'Pausar', retry: 'Tentar novamente', back10: 'Voltar 10 segundos', forward10: 'Avançar 10 segundos', goLive: 'Voltar ao vivo',
    expired: 'A pausa ultrapassou o limite salvo. A reprodução voltou ao ponto salvo mais antigo.',
    recording: (seconds: number, megabytes: number) => `Salvando TV ao vivo no armazenamento temporário · ${seconds} segundos salvos · ${megabytes} MB`,
    checking: 'Verificando o suporte a voltar na transmissão…', behind: (seconds: number) => `· ${seconds} segundos atrás da transmissão`,
  },
} as const;

const recorderMessages: Record<string, string> = {
  'This HLS sequence is not supported for live rewind.': 'Esta sequência HLS não permite voltar na transmissão.',
  'Live rewind requires an HLS playlist.': 'Para voltar na transmissão, é necessária uma lista HLS.',
  'This HLS format is not supported for live rewind.': 'Este formato HLS não permite voltar na transmissão.',
  'This HLS segment duration is not supported for live rewind.': 'A duração deste segmento HLS não permite voltar na transmissão.',
  'Encrypted streams play directly without local live rewind.': 'Transmissões criptografadas são reproduzidas diretamente, sem voltar na transmissão.',
  'This HLS initialization format is not supported for live rewind.': 'Este formato de inicialização HLS não permite voltar na transmissão.',
  'Changing HLS initialization is not supported for live rewind.': 'Não é possível alterar a inicialização HLS durante a gravação.',
  'This HLS playlist has an incomplete segment.': 'Esta lista HLS tem um segmento incompleto.',
  'This HLS playlist cannot provide a bounded live buffer.': 'Esta lista HLS não permite criar um buffer temporário limitado.',
  'Separate HLS audio or subtitle renditions play directly without local live rewind.': 'Faixas separadas de áudio ou legenda são reproduzidas diretamente, sem voltar na transmissão.',
  'Separate HLS renditions play directly without local live rewind.': 'Faixas HLS separadas são reproduzidas diretamente, sem voltar na transmissão.',
  'This HLS master playlist is not supported for live rewind.': 'Esta lista principal HLS não permite voltar na transmissão.',
  'The temporary live buffer could not be read.': 'Não foi possível ler o buffer temporário da transmissão.',
  'Nested HLS masters are not supported for live rewind.': 'Listas principais HLS aninhadas não permitem voltar na transmissão.',
  'This provider does not supply bounded downloads for live rewind.': 'O provedor não permite downloads limitados para voltar na transmissão.',
  'This provider exceeded the live-buffer download limit.': 'O provedor ultrapassou o limite de download do buffer temporário.',
  'This stream exceeds the temporary live-buffer size limit.': 'Esta transmissão ultrapassa o limite de tamanho do buffer temporário.',
  'Temporary storage is unavailable for live rewind.': 'O armazenamento temporário está indisponível para voltar na transmissão.',
  'Temporary storage could not reclaim the live buffer.': 'Não foi possível liberar espaço para o buffer temporário.',
  'The temporary live buffer reached its storage limit.': 'O buffer temporário atingiu o limite de armazenamento.',
  'The provider restarted its live timeline. Live rewind is unavailable for this session.': 'O provedor reiniciou a transmissão. Não é possível voltar nesta sessão.',
  'The provider reset its HLS discontinuity timeline. Live rewind is unavailable for this session.': 'O provedor reiniciou a linha do tempo HLS. Não é possível voltar nesta sessão.',
  'The provider skipped too much live content to maintain a rewind buffer.': 'O provedor avançou demais para manter o buffer temporário.',
  'No playable content is available in the live buffer.': 'Não há conteúdo reproduzível no buffer temporário.',
  'Live recording stopped after repeated provider errors. Reopen the channel to reconnect.': 'A gravação parou após várias falhas do provedor. Abra o canal novamente para reconectar.',
  'Reconnecting the live buffer. Saved content is still available.': 'Reconectando o buffer temporário. O conteúdo salvo ainda está disponível.',
  'Local live rewind is unavailable. Playing the provider directly.': 'Não é possível voltar nesta transmissão. Reproduzindo diretamente do provedor.',
  'The temporary live buffer could not be played on this device.': 'Não foi possível reproduzir o buffer temporário da transmissão neste dispositivo.',
  'Use HLS, DASH or an MP4 source on this Vega starter.': 'Este app Vega reproduz fontes HLS, DASH ou MP4.',
  'Local live recording stopped.': 'A gravação temporária da transmissão parou.',
};

const providerFallbackSuffix = ' Playing the provider directly without local rewind.';

export function playerText(language: PlayerLanguage) {
  return copy[language];
}

export function localizePlayerMessage(message: string | undefined, language: PlayerLanguage): string | undefined {
  if (!message || language === 'en') return message;
  if (message.endsWith(providerFallbackSuffix)) {
    const base = message.slice(0, -providerFallbackSuffix.length);
    return `${recorderMessages[base] ?? base} Reproduzindo diretamente do provedor.`;
  }
  return recorderMessages[message] ?? message;
}

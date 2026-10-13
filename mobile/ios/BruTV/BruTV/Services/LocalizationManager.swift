import Foundation
import SwiftUI

public enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system = "system"
    case english = "en"
    case portuguese = "pt-BR"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system:
            return LocalizationManager.shared.isPortuguese ? "Automático (Padrão do Sistema)" : "System Default"
        case .english:
            return "English"
        case .portuguese:
            return "Português (Brasil)"
        }
    }
}

public final class LocalizationManager: ObservableObject {
    public static let shared = LocalizationManager()

    private let languageKey = "brutv.settings.language"

    @Published public var selectedLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: languageKey)
            updateEffectiveLanguage()
        }
    }

    @Published public private(set) var isPortuguese: Bool = false

    private init() {
        if let saved = UserDefaults.standard.string(forKey: languageKey),
           let lang = AppLanguage(rawValue: saved) {
            self.selectedLanguage = lang
        } else {
            self.selectedLanguage = .system
        }
        updateEffectiveLanguage()
    }

    private func updateEffectiveLanguage() {
        switch selectedLanguage {
        case .english:
            isPortuguese = false
        case .portuguese:
            isPortuguese = true
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
            let code = Locale.current.language.languageCode?.identifier.lowercased() ?? ""
            isPortuguese = preferred.hasPrefix("pt") || code.hasPrefix("pt")
        }
    }

    public func t(_ key: String) -> String {
        guard isPortuguese else {
            return translationsEN[key] ?? key
        }
        return translationsPT[key] ?? translationsEN[key] ?? key
    }

    // Comprehensive Portuguese (Brazil) translations dictionary
    private let translationsPT: [String: String] = [
        // MARK: - Navigation & General
        "BruTV": "BruTV",
        "Home": "Início",
        "Live TV": "TV ao Vivo",
        "Movies": "Filmes",
        "Series": "Séries",
        "Favorites": "Favoritos",
        "Settings": "Configurações",
        "Search": "Buscar",
        "Connected": "Conectado",
        "Viewer": "Espectador",
        "Cancel": "Cancelar",
        "Confirm": "Confirmar",
        "Back": "Voltar",
        "Back to Channels": "Voltar aos Canais",
        "Retry": "Tentar novamente",
        "Close": "Fechar",
        "Loading": "Carregando...",
        "OK": "OK",
        "Clear": "Limpar",
        "Done": "Concluído",
        "Copied": "Copiado",
        "Copy Link": "Copiar Link",
        "Share QR": "Compartilhar QR",
        "Choose Photo": "Escolher Foto",
        "Open Settings": "Abrir Ajustes",
        "Minimize": "Minimizar",
        "Stop": "Parar",

        // MARK: - App Splash & Sign In
        "IPTV that just works.": "IPTV simples e direto ao ponto.",
        "Signing in to BruTV...": "Conectando ao BruTV...",
        "Could not sign in": "Não foi possível conectar",
        "This BruTV link is not valid.": "Este link do BruTV não é válido.",

        // MARK: - Login Screen
        "Login type": "Tipo de acesso",
        "Xtream Codes": "Xtream Codes",
        "M3U Playlist": "Lista M3U",
        "Connect Server": "Conectar ao Servidor",
        "Load Playlist": "Carregar Lista",
        "Connecting...": "Conectando...",
        "Scan QR Code": "Escanear QR Code",
        "Scan a BruTV sign-in QR code with the camera or from a photo.": "Escaneie o QR Code de acesso do BruTV com a câmera ou foto.",
        "Paste a BruTV sign-in link or playlist URL.": "Cole um link de acesso ou URL de lista de reprodução.",
        "Got a BruTV QR code? Tap Scan QR Code. Got a link? Copy it, then tap Paste.": "Tem um QR Code do BruTV? Toque em Escanear. Tem um link? Copie e toque em Colar.",
        "Fill Demo Credentials (example.invalid)": "Preencher Dados de Demonstração (example.invalid)",
        "SAVED PROFILES": "PERFIS SALVOS",
        "SERVER ADDRESS": "ENDEREÇO DO SERVIDOR",
        "USERNAME": "USUÁRIO",
        "PASSWORD": "SENHA",
        "PLAYLIST URL": "URL DA LISTA",
        "Username": "Usuário",
        "Password": "Senha",
        "Hide password": "Ocultar senha",
        "Show password": "Exibir senha",
        "Hides your password.": "Oculta sua senha.",
        "Shows your password.": "Exibe sua senha.",
        "Paste an .m3u or .m3u8 link. Xtream get.php links unlock movies and series too.": "Cole um link .m3u ou .m3u8. Links Xtream get.php também liberam filmes e séries.",
        "The clipboard does not contain a BruTV link or playlist URL.": "A área de transferência não contém um link do BruTV ou URL de lista.",

        // MARK: - Login QR Scanner & Sharing
        "Sign-In QR Code": "QR Code de Acesso",
        "Sign-in QR code": "QR Code de acesso",
        "Scan with the Camera app on iPhone or iPad. BruTV opens and signs in.": "Escaneie com a Câmera do iPhone ou iPad. O BruTV abrirá e conectará automaticamente.",
        "BruTV sign-in for %@": "Acesso ao BruTV para %@",
        "This code contains the password. Share it only with people you trust. Anyone with it can use this subscription.": "Este código contém a senha. Compartilhe apenas com pessoas de confiança. Qualquer pessoa com ele pode usar esta assinatura.",
        "Point the camera at a BruTV sign-in QR code.": "Aponte a câmera para o QR Code de acesso do BruTV.",
        "Camera access is off for BruTV.": "O acesso à câmera está desativado para o BruTV.",
        "No camera is available. Choose a photo of the QR code instead.": "Nenhuma câmera disponível. Escolha uma foto do QR Code.",
        "That photo could not be opened.": "Não foi possível abrir esta foto.",
        "No BruTV QR code was found in that photo.": "Nenhum QR Code do BruTV foi encontrado nesta foto.",
        "This QR code is not a BruTV sign-in code.": "Este QR Code não é um código de acesso do BruTV.",

        // MARK: - Home View
        "BruTV Home": "Início BruTV",
        "Welcome back, %@": "Bem-vindo de volta, %@",
        "Discover live channels, top movies and series": "Descubra canais ao vivo, filmes e séries",
        "FEATURED MOVIE": "FILME EM DESTAQUE",
        "Play Movie": "Assistir Filme",
        "Watch Series": "Assistir Série",
        "Recently Watched": "Assistidos Recentemente",
        "Favorite Channels": "Canais Favoritos",
        "Top Rated Movies": "Filmes Mais Votados",
        "Top Rated Series": "Séries Mais Votadas",
        "High Ratings": "Mais Votados",
        "Popular": "Populares",
        "No channels watched yet": "Nenhum canal assistido ainda",
        "No recently watched channels": "Nenhum canal assistido recentemente",
        "Tune into any Live TV channel to see your recent history here.": "Assista a qualquer canal de TV ao vivo para ver seu histórico aqui.",
        "No favorites added yet": "Nenhum favorito adicionado ainda",
        "Tap the heart icon on any channel to pin it right to your home screen.": "Toque no ícone de coração em qualquer canal para fixá-lo aqui.",
        "Tap the heart icon on any channel to pin it here.": "Toque no ícone de coração em qualquer canal para fixá-lo aqui.",
        "Refresh home recommendations": "Atualizar recomendações do início",

        // MARK: - Live TV View
        "All Channels": "Todos os Canais",
        "Search channels...": "Buscar canais...",
        "Clear search": "Limpar busca",
        "Removes the channel search text.": "Remove o texto de busca de canais.",
        "Categories": "Categorias",
        "No channels found": "Nenhum canal encontrado",
        "channels": "canais",
        "Loading channels...": "Carregando canais...",
        "Try adjusting your search query or category filter.": "Tente ajustar sua busca ou filtro de categoria.",

        // MARK: - VOD & Series
        "All Movies": "Todos os Filmes",
        "Search movies...": "Buscar filmes...",
        "Removes the movie search text.": "Remove o texto de busca de filmes.",
        "No movies found": "Nenhum filme encontrado",
        "All Series": "Todas as Séries",
        "Search series...": "Buscar séries...",
        "Removes the series search text.": "Remove o texto de busca de séries.",
        "No series found": "Nenhuma série encontrada",
        "Overview": "Sinopse",
        "Cast": "Elenco",
        "Director": "Direção",
        "Director: %@": "Direção: %@",
        "Genre": "Gênero",
        "Seasons": "Temporadas",
        "Season": "Temporada",
        "Season %@": "Temporada %@",
        "Episodes": "Episódios",
        "Episode": "Episódio",
        "Loading seasons & episodes...": "Carregando temporadas e episódios...",
        "Failed to load episodes: %@": "Falha ao carregar episódios: %@",
        "No episodes available": "Nenhum episódio disponível",
        "%d episodes": "%d episódios",
        "1 episode": "1 episódio",
        "%d min": "%d min",

        // MARK: - Player & Overlays
        "Connecting to stream...": "Conectando ao canal...",
        "Buffering broadcast...": "Carregando transmissão...",
        "Buffering...": "Carregando...",
        "Playback Error": "Erro de Reprodução",
        "Open in VLC": "Abrir no VLC",
        "Channel Guide": "Guia de Canais",
        "Close Guide": "Fechar Guia",
        "Close Player": "Fechar Reprodutor",
        "LIVE": "AO VIVO",
        "DELAYED": "ATRASADO",
        "SERIES": "SÉRIE",
        "MOVIE": "FILME",
        "Rewind 10 seconds": "Voltar 10 segundos",
        "Forward 10 seconds": "Avançar 10 segundos",
        "Fast forward 10 seconds": "Avançar 10 segundos",
        "Pause": "Pausar",
        "Play": "Reproduzir",
        "Mute": "Mudo",
        "Unmute": "Ativar som",
        "Mute audio": "Silenciar áudio",
        "Unmute audio": "Ativar som do áudio",
        "Stop": "Parar",
        "Previous Channel": "Canal Anterior",
        "Next Channel": "Próximo Canal",
        "Previous channel": "Canal anterior",
        "Next channel": "Próximo canal",
        "Audio & Subtitles": "Áudio e Legendas",
        "Audio and Subtitles": "Áudio e Legendas",
        "Audio language": "Idioma do Áudio",
        "Audio Track": "Faixa de Áudio",
        "Default Audio": "Áudio Padrão",
        "Subtitles": "Legendas",
        "Off": "Desativado",
        "Live rewind position": "Posição de retorno ao vivo",
        "Playback progress scrubber": "Barra de progresso de reprodução",
        "Stop playback": "Parar reprodução",
        "Pause playback": "Pausar reprodução",
        "Resume playback": "Retomar reprodução",
        "Stop playback and return": "Parar reprodução e voltar",
        "Stop playback and return to channels": "Parar reprodução e voltar aos canais",
        "Keep playing in the mini player": "Continuar assistindo no mini reprodutor",
        "Close player and stop playback": "Fechar reprodutor e parar reprodução",
        "Opens the full screen player": "Abre o reprodutor em tela cheia",
        "Browse channels": "Navegar pelos canais",
        "Select audio language and subtitles": "Selecionar idioma do áudio e legendas",
        "Show or hide stream telemetry": "Exibir ou ocultar estatísticas técnicas",
        "More Options": "Mais Opções",
        "Change Aspect Ratio": "Alterar Proporção da Tela",
        "Aspect": "Proporção",
        "Aspect: %@": "Proporção: %@",
        "Aspect ratio": "Proporção da tela",
        "Aspect ratio: %@": "Proporção da tela: %@",
        "Fit Screen": "Ajustar à Tela",
        "Fill Screen": "Preencher Tela",
        "16 : 9 Widescreen": "16 : 9 Widescreen",
        "4 : 3 Classic": "4 : 3 Clássico",
        "Stream Telemetry HUD": "Estatísticas Técnicas (HUD)",
        "Hide Stream Stats": "Ocultar Estatísticas",
        "Show Stream Stats": "Exibir Estatísticas",
        "Picture in Picture": "Picture in Picture",
        "Exit Picture in Picture": "Sair do Picture in Picture",
        "Enter Full Screen": "Tela Cheia",
        "Exit Full Screen": "Sair da Tela Cheia",
        "Full Screen": "Tela Cheia",
        "GO LIVE": "AO VIVO",
        "Buffer": "Buffer",
        "Buffer %@": "Buffer %@",
        "Live • %@ buffered": "Ao Vivo • %@ em buffer",
        "Live": "Ao Vivo",
        "buffered": "em buffer",
        "Series Playing": "Reproduzindo Série",
        "Movie Playing": "Reproduzindo Filme",
        "Paused": "Pausado",

        // MARK: - Channel Card
        "Live Broadcast": "Transmissão ao Vivo",
        "Play %@": "Assistir a %@",
        "Channel %d, %@": "Canal %d, %@",
        "Remove %@ from Favorites": "Remover %@ dos Favoritos",
        "Add %@ to Favorites": "Adicionar %@ aos Favoritos",
        "Remove favorite": "Remover favorito",
        "Add favorite": "Adicionar aos favoritos",

        // MARK: - Tech Stats HUD
        "STREAM TELEMETRY": "ESTATÍSTICAS DA TRANSMISSÃO",
        "Buffer Ahead": "Buffer à Frente",
        "Resolution": "Resolução",
        "Bitrate": "Taxa de Bits",
        "Dropped Frames": "Quadros Perdidos",
        "Stalls Count": "Travamentos",
        "Analyzing...": "Analisando...",
        "Local Stream": "Transmissão Local",
        "Auto / Detecting": "Automático / Detectando",

        // MARK: - Settings View
        "LANGUAGE": "IDIOMA",
        "LANGUAGE & REGION": "IDIOMA E REGIÃO",
        "Choose the language for BruTV interface and menus.": "Escolha o idioma para os menus e interface do BruTV.",
        "Language": "Idioma",
        "ACCOUNT & SUBSCRIPTION": "CONTA E ASSINATURA",
        "Username": "Usuário",
        "Status": "Status",
        "Expires": "Expira em",
        "Max Connections": "Conexões Máximas",
        "Source": "Origem",
        "Server Address": "Endereço do Servidor",
        "Playlist": "Lista de Reprodução",
        "M3U Playlist": "Lista M3U",
        "Xtream Codes": "Xtream Codes",
        "Share Sign-In QR Code": "Compartilhar QR Code de Acesso",
        "PLAYBACK & BUFFERING ENGINE": "REPRODUÇÃO E MOTOR DE BUFFER",
        "Buffer Profile": "Perfil de Buffer",
        "Stream Protocol": "Protocolo de Transmissão",
        "Hardware Acceleration": "Aceleração por Hardware",
        "LIVE REWIND": "VOLTAR AO VIVO (TIMESHIFT)",
        "Pause & Rewind Live TV": "Pausar e Voltar TV ao Vivo",
        "CACHE & DATA": "CACHE E DADOS",
        "CACHE & STORAGE": "CACHE E ARMAZENAMENTO",
        "Clear Logo & Poster Cache": "Limpar Cache de Logos e Capas",
        "Clear Image Cache": "Limpar Cache de Imagens",
        "Clear Image & Catalog Cache": "Limpar Cache de Imagens e Catálogo",
        "Refresh Channel Listings": "Atualizar Lista de Canais",
        "Log Out & Switch Server": "Sair e Trocar de Servidor",
        "Log Out": "Sair da Conta",
        "Settings & Engine": "Configurações e Reprodução",
        "SIGN OUT": "DESCONECTAR",
        "Sign Out of BruTV": "Sair do BruTV",
        "Are you sure you want to sign out?": "Tem certeza que deseja sair da conta?",
        "Are you sure you want to log out of this IPTV server?": "Tem certeza de que deseja sair deste servidor IPTV?",
        "Are you sure you want to clear the local image and catalog cache?": "Tem certeza que deseja limpar o cache local de imagens e catálogo?",
        "This will clear temporarily cached channel logos and movie covers.": "Isso limpará logos de canais e capas de filmes armazenados temporariamente.",

        // Buffer Profiles & Formats
        "Ultra Low Latency (1.5s)": "Latência Ultra Baixa (1.5s)",
        "Balanced / Default (4.0s)": "Equilibrado / Padrão (4.0s)",
        "High Stability / Cellular (10.0s)": "Alta Estabilidade / Dados Móveis (10.0s)",
        "Apple HLS (.m3u8)": "Apple HLS (.m3u8)",
        "MPEG-TS (.ts, most compatible)": "MPEG-TS (.ts, mais compatível)",
        "Ultra Low Latency (1.5s) delivers near-live sports broadcast timing. Balanced (4.0s) ensures zero stuttering on regular broadband. High Stability (10.0s) protects against cellular jitter.": "Latência Ultra Baixa (1.5s) oferece transmissão esportiva quase em tempo real. Equilibrado (4.0s) garante reprodução contínua em banda larga. Alta Estabilidade (10.0s) protege contra variações de rede móvel.",
        "When on, BruTV records live channels on this device so you can pause and rewind. Channels take longer to start, because BruTV records about 30 seconds first, and some providers are too slow for it. When off, channels start right away, and you can pause briefly within the provider's own live window. Up to 10 minutes is kept within a 256 MiB temporary-file limit. Closing playback or changing channels deletes the recording.": "Quando ativado, o BruTV grava os canais ao vivo no aparelho para permitir pausar e voltar. Os canais demoram mais para iniciar porque cerca de 30 segundos são gravados antes, e alguns servidores são lentos. Desativado, iniciam imediatamente e a pausa segue a janela do provedor. Até 10 minutos (limite de 256 MiB) são mantidos. Fechar ou trocar de canal exclui a gravação.",

        // Playback Errors & Messages
        "Invalid stream URL.": "URL de transmissão inválida.",
        "Invalid movie URL.": "URL de filme inválida.",
        "Invalid episode URL.": "URL de episódio inválida.",
        "Stream unavailable or connection lost.": "Transmissão indisponível ou conexão perdida.",
        "Failed to load media.": "Falha ao carregar mídia.",
        "The server returned an invalid response.": "O servidor retornou uma resposta inválida.",
        "Network connection timed out.": "Tempo limite de conexão esgotado.",
        "The stream could not be loaded.": "Não foi possível carregar a transmissão."
    ]

    private let translationsEN: [String: String] = [:]
}

extension String {
    public var localized: String {
        LocalizationManager.shared.t(self)
    }
}

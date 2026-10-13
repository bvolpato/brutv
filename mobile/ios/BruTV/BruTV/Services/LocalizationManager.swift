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

    // Portuguese (Brazil) translations dictionary
    private let translationsPT: [String: String] = [
        // Navigation & General
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

        // Home View
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

        // Player & Overlays
        "Connecting to stream...": "Conectando ao canal...",
        "Buffering broadcast...": "Carregando transmissão...",
        "Buffering...": "Carregando...",
        "Playback Error": "Erro de Reprodução",
        "Open in VLC": "Abrir no VLC",
        "Channel Guide": "Guia de Canais",
        "Close Guide": "Fechar Guia",
        "LIVE": "AO VIVO",
        "channels": "canais",
        "Loading channels...": "Carregando canais...",
        "Try adjusting your search query or category filter.": "Tente ajustar sua busca ou filtro de categoria.",
        "Rewind 10 seconds": "Voltar 10 segundos",
        "Forward 10 seconds": "Avançar 10 segundos",
        "Pause": "Pausar",
        "Play": "Reproduzir",
        "Mute": "Mudo",
        "Unmute": "Ativar som",
        "Stop": "Parar",
        "Audio & Subtitles": "Áudio e Legendas",
        "Audio language": "Idioma do Áudio",
        "Subtitles": "Legendas",
        "Off": "Desativado",
        "Live rewind position": "Posição de retorno ao vivo",
        "Playback progress scrubber": "Barra de progresso de reprodução",
        "Stop playback": "Parar reprodução",
        "Pause playback": "Pausar reprodução",
        "Resume playback": "Retomar reprodução",
        "Next channel": "Próximo canal",
        "Previous channel": "Canal anterior",

        // Live TV View
        "All Channels": "Todos os Canais",
        "Search channels...": "Buscar canais...",
        "Clear search": "Limpar busca",
        "Categories": "Categorias",
        "No channels found": "Nenhum canal encontrado",

        // VOD & Series
        "All Movies": "Todos os Filmes",
        "Search movies...": "Buscar filmes...",
        "All Series": "Todas as Séries",
        "Search series...": "Buscar séries...",
        "Seasons": "Temporadas",
        "Season": "Temporada",
        "Episodes": "Episódios",
        "Episode": "Episódio",
        "Overview": "Sinopse",
        "Cast": "Elenco",
        "Director": "Direção",
        "Genre": "Gênero",

        // Settings View
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
        "Stream Telemetry HUD": "Estatísticas Técnicas (HUD)",
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
        "Clear": "Limpar",
        "Settings & Engine": "Configurações e Reprodução",
        "SIGN OUT": "DESCONECTAR",
        "Sign Out of BruTV": "Sair do BruTV",
        "Are you sure you want to sign out?": "Tem certeza que deseja sair da conta?",
        "Are you sure you want to log out of this IPTV server?": "Tem certeza de que deseja sair deste servidor IPTV?",
        "Are you sure you want to clear the local image and catalog cache?": "Tem certeza que deseja limpar o cache local de imagens e catálogo?",
        "This will clear temporarily cached channel logos and movie covers.": "Isso limpará logos de canais e capas de filmes armazenados temporariamente."
    ]

    private let translationsEN: [String: String] = [
        "Home": "Home",
        "Live TV": "Live TV",
        "Movies": "Movies",
        "Series": "Series",
        "Favorites": "Favorites",
        "Settings": "Settings"
    ]
}

extension String {
    public var localized: String {
        LocalizationManager.shared.t(self)
    }
}

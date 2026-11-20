import Foundation

extension Notification.Name {
    /// Изменились настройки браузера (поисковик, положение адресной строки и т. п.).
    static let appSettingsChanged = Notification.Name("KentikAppSettingsChanged")
}

/// Поисковые системы для адресной строки.
enum SearchEngine: String, CaseIterable, Identifiable {
    case google, yandex, duckduckgo, bing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google"
        case .yandex: return "Яндекс"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        }
    }

    /// Адрес страницы поиска без параметров.
    var searchBase: String {
        switch self {
        case .google: return "https://www.google.com/search"
        case .yandex: return "https://yandex.ru/search/"
        case .duckduckgo: return "https://duckduckgo.com/"
        case .bing: return "https://www.bing.com/search"
        }
    }

    /// Имя параметра с запросом.
    var queryName: String {
        self == .yandex ? "text" : "q"
    }
}

/// Где адресная строка.
enum AddressBarPosition: String, CaseIterable, Identifiable {
    case bottom, top
    var id: String { rawValue }
    var title: String { self == .bottom ? "Снизу" : "Сверху" }
}

/// Настройки браузера (кроме щита — те в BlockingSettings). Хранятся в UserDefaults.
@MainActor
final class AppSettings {

    static let shared = AppSettings()

    private let defaults: UserDefaults

    private enum Key {
        static let searchEngine = "settings.searchEngine"
        static let addressBar = "settings.addressBarPosition"
        static let incognitoFaceID = "settings.incognitoFaceID"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var searchEngine: SearchEngine {
        get { defaults.string(forKey: Key.searchEngine).flatMap(SearchEngine.init(rawValue:)) ?? .google }
        set {
            defaults.set(newValue.rawValue, forKey: Key.searchEngine)
            applySearchEngine()
            notify()
        }
    }

    var addressBarPosition: AddressBarPosition {
        get { defaults.string(forKey: Key.addressBar).flatMap(AddressBarPosition.init(rawValue:)) ?? .bottom }
        set {
            defaults.set(newValue.rawValue, forKey: Key.addressBar)
            notify()
        }
    }

    /// Face ID для вкладок инкогнито (по умолчанию выключено).
    var incognitoFaceID: Bool {
        get { defaults.bool(forKey: Key.incognitoFaceID) }
        set {
            defaults.set(newValue, forKey: Key.incognitoFaceID)
            notify()
        }
    }

    /// Передаёт выбранный поисковик в AddressParser.
    func applySearchEngine() {
        let engine = searchEngine
        AddressParser.searchBase = engine.searchBase
        AddressParser.searchQueryName = engine.queryName
    }

    private func notify() {
        NotificationCenter.default.post(name: .appSettingsChanged, object: self)
    }

    /// Версия приложения для экрана «О приложении».
    nonisolated static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

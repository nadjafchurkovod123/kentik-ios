import Foundation

/// Хранимые настройки щита: общий выключатель и список сайтов, где щит выключен.
/// Сайт = регистрируемый домен (приближение eTLD+1, см. DomainMatcher): выключение на
/// «kinogo.ru» действует и на «m.kinogo.ru». Вкладки инкогнито видят постоянные настройки,
/// но их собственные выключатели сайтов живут только в памяти (`incognitoOverrides`) и
/// стираются вместе с сессией инкогнито — на диске и в настройках от инкогнито следа нет.
@MainActor
final class BlockingSettings {

    static let shared = BlockingSettings()

    private let defaults: UserDefaults

    private enum Key {
        static let enabled = "shield.enabled"
        static let disabledHosts = "shield.disabledHosts"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Щит включён везде (по умолчанию — да).
    var isEnabledGlobally: Bool {
        // bool(forKey:) понимает и строки ("NO", "0") — так значение можно задать аргументом
        // запуска (-shield.enabled NO) в UI-тестах.
        get { defaults.object(forKey: Key.enabled) == nil ? true : defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Сайты (регистрируемые домены), где щит выключен.
    private(set) var disabledHosts: Set<String> {
        get { Set((defaults.stringArray(forKey: Key.disabledHosts) ?? []).map(Self.normalize)) }
        set { defaults.set(newValue.sorted(), forKey: Key.disabledHosts) }
    }

    /// Выключатели сайтов из вкладок инкогнито: сайт → включён ли щит. Только в памяти.
    private(set) var incognitoOverrides: [String: Bool] = [:]

    func isEnabled(forHost host: String?) -> Bool {
        isEnabled(forHost: host, incognito: false)
    }

    /// Включён ли щит на сайте для вкладки (инкогнито учитывает свои временные выключатели).
    func isEnabled(forHost host: String?, incognito: Bool) -> Bool {
        guard isEnabledGlobally else { return false }
        guard let host, !host.isEmpty else { return true }
        let key = Self.normalize(host)
        if incognito, let override = incognitoOverrides[key] { return override }
        return !disabledHosts.contains(key)
    }

    func setEnabled(_ enabled: Bool, forHost host: String) {
        let key = Self.normalize(host)
        guard !key.isEmpty else { return }
        var hosts = disabledHosts
        if enabled { hosts.remove(key) } else { hosts.insert(key) }
        disabledHosts = hosts
    }

    /// Выключатель из вкладки: в инкогнито — только до конца сессии инкогнито.
    func setEnabled(_ enabled: Bool, forHost host: String, incognito: Bool) {
        guard incognito else { return setEnabled(enabled, forHost: host) }
        let key = Self.normalize(host)
        guard !key.isEmpty else { return }
        incognitoOverrides[key] = enabled
    }

    /// Сайты, где щит выключен, — для вкладок инкогнито (постоянные с учётом временных).
    var incognitoDisabledHosts: Set<String> {
        var hosts = disabledHosts
        for (host, enabled) in incognitoOverrides {
            if enabled { hosts.remove(host) } else { hosts.insert(host) }
        }
        return hosts
    }

    /// Сессия инкогнито закончилась — забыть её выключатели.
    func resetIncognitoOverrides() {
        incognitoOverrides.removeAll()
    }

    /// "WWW.M.Example.com" → "example.com" (регистрируемый домен).
    nonisolated static func normalize(_ host: String) -> String {
        DomainMatcher.registrableDomain(of: host)
    }
}

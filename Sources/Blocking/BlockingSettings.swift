import Foundation

/// Хранимые настройки щита: общий выключатель и список сайтов, где щит выключен.
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
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Сайты (нормализованные хосты), где щит выключен.
    private(set) var disabledHosts: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.disabledHosts) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.disabledHosts) }
    }

    func isEnabled(forHost host: String?) -> Bool {
        guard isEnabledGlobally else { return false }
        guard let host, !host.isEmpty else { return true }
        return !disabledHosts.contains(Self.normalize(host))
    }

    func setEnabled(_ enabled: Bool, forHost host: String) {
        let key = Self.normalize(host)
        guard !key.isEmpty else { return }
        var hosts = disabledHosts
        if enabled { hosts.remove(key) } else { hosts.insert(key) }
        disabledHosts = hosts
    }

    /// "WWW.Example.com" → "example.com".
    nonisolated static func normalize(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }
}

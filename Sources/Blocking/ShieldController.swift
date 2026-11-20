import Foundation

/// Реализация ShieldControlling: склеивает настройки (BlockingSettings), блокировщик
/// (ContentBlocker) и счётчики защиты на вкладках (Guard пишет их в Tab).
@MainActor
final class ShieldController: ShieldControlling {

    static let shared = ShieldController(settings: .shared)

    private let settings: BlockingSettings

    init(settings: BlockingSettings) {
        self.settings = settings
    }

    var isEnabledGlobally: Bool {
        get { settings.isEnabledGlobally }
        set {
            guard newValue != settings.isEnabledGlobally else { return }
            settings.isEnabledGlobally = newValue
            notify()
        }
    }

    func isEnabled(forHost host: String?) -> Bool {
        settings.isEnabled(forHost: host)
    }

    func setEnabled(_ enabled: Bool, forHost host: String) {
        settings.setEnabled(enabled, forHost: host)
        notify()
    }

    func stats(for tab: Tab) -> ShieldStats {
        ShieldStats(
            blockedPopups: tab.blockedPopups,
            blockedRedirects: tab.blockedRedirects,
            hiddenElements: tab.hiddenElements,
            listsVersion: ContentBlocker.shared.activeVersion ?? FilterLists.version
        )
    }

    /// «Обновить списки»: проверка обновления (без ограничения «раз в сутки») и перекомпиляция.
    func reloadRules(completion: @escaping @MainActor (Error?) -> Void) {
        ContentBlocker.shared.reloadRules { [weak self] error in
            self?.notify()
            completion(error)
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: .shieldSettingsChanged, object: self)
    }
}

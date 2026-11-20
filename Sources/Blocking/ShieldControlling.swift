import Foundation

extension Notification.Name {
    /// Настройки щита изменились (глобальный выключатель, сайт, списки).
    /// UI перезагружает текущую вкладку.
    static let shieldSettingsChanged = Notification.Name("KentikShieldSettingsChanged")
}

/// Статистика щита для одной вкладки.
struct ShieldStats: Equatable {
    var blockedPopups: Int
    var blockedRedirects: Int
    /// Примерное число скрытых элементов (косметические правила).
    var hiddenElements: Int
    /// Версия встроенных списков фильтров.
    var listsVersion: String
}

/// Управление щитом (блокировщик рекламы + защита от всплывающих окон и переходов),
/// как в AdBlock: общий выключатель и выключатель на сайт.
/// Реализуют модули Blocking и Guard, использует UI.
@MainActor
protocol ShieldControlling: AnyObject {
    var isEnabledGlobally: Bool { get set }
    /// Включён ли щит для хоста (nil — просто глобальное состояние).
    func isEnabled(forHost host: String?) -> Bool
    func setEnabled(_ enabled: Bool, forHost host: String)
    func stats(for tab: Tab) -> ShieldStats
    /// Перекомпилировать правила (например, после обновления списков).
    func reloadRules(completion: @escaping @MainActor (Error?) -> Void)
}

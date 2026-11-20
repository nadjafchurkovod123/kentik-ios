import WebKit

/// Защита от рекламных перенаправлений (клик по плееру уводит вкладку на рекламу).
///
/// Каркас: пропускает всё. Правила добавит агент Guard. Если вернуть `.cancel`,
/// Browser увеличит счётчик blockedRedirects вкладки.
@MainActor
final class RedirectGuard {

    static let shared = RedirectGuard()

    func decide(navigationAction: WKNavigationAction, tab: Tab) -> WKNavigationActionPolicy {
        // TODO(guard): отменять переходы главного фрейма на рекламные домены без жеста пользователя.
        return .allow
    }
}

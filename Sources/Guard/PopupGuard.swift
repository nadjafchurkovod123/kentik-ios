import WebKit

/// Решение о новом окне (window.open, target=_blank).
enum PopupDecision: Equatable {
    /// Открыть во вкладке; background — не переключаться на неё.
    case allowNewTab(background: Bool)
    /// Не открывать (реклама, попандер). reason — для журнала и статистики.
    case block(reason: String)
}

/// Защита от всплывающих окон и попандеров.
///
/// Каркас: пропускает всё. Эвристики (жест пользователя, сторонний домен, попандеры
/// на сайтах с сериалами и т. п.) добавит агент Guard.
@MainActor
final class PopupGuard {

    static let shared = PopupGuard()

    func decide(
        createWebViewWith configuration: WKWebViewConfiguration,
        navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures,
        tab: Tab
    ) -> PopupDecision {
        // TODO(guard): блокировать окна без жеста пользователя и рекламные домены.
        return .allowNewTab(background: false)
    }
}

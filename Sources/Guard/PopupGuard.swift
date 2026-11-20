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
/// Первый слой — скриплет в странице (Scriptlets): он подменяет window.open и гасит
/// программные клики по ссылкам target=_blank, так что большинство попандеров сюда даже
/// не доходит. Сюда попадают окна, которые WebKit всё же хочет открыть (по жесту
/// пользователя — javaScriptCanOpenWindowsAutomatically выключен). Правило простое:
/// новая вкладка открывается только для настоящего касания обычной ссылки в главном фрейме
/// и не на рекламный адрес; окна от входа через OAuth тоже пропускаем. Остальное —
/// блокируем и показываем плашку «Всплывающее окно заблокировано · Открыть».
@MainActor
final class PopupGuard {

    static let shared = PopupGuard()

    /// Сколько секунд после касания ссылки окно считается открытым пользователем.
    static let tapWindow: TimeInterval = 3

    /// Всё, что нужно для решения, без объектов WebKit (так решение легко проверять тестами).
    struct Request {
        var url: URL?
        /// navigationType == .linkActivated (клик по ссылке target=_blank).
        var isLinkActivation: Bool
        /// Окно просит главный фрейм вкладки (а не iframe).
        var fromMainFrame: Bool
        /// Хост страницы во вкладке — по нему проверяется выключатель щита на сайте.
        var pageHost: String?
    }

    var isShieldEnabled: @MainActor (String?) -> Bool = { ShieldController.shared.isEnabled(forHost: $0) }
    var adHosts: AdHosts = .shared

    func decide(
        createWebViewWith configuration: WKWebViewConfiguration,
        navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures,
        tab: Tab
    ) -> PopupDecision {
        let request = Request(
            url: navigationAction.request.url,
            isLinkActivation: navigationAction.navigationType == .linkActivated,
            fromMainFrame: GuardFrames.sourceFrame(of: navigationAction)?.isMainFrame ?? true,
            pageHost: tab.host
        )
        let decision = evaluate(request, state: GuardState.shared.state(for: tab), now: Date())
        if case .block = decision {
            BlockedNoticeBar.show(.popup, url: request.url, on: tab)
        }
        return decision
    }

    /// Чистое решение по описанию окна и состоянию вкладки.
    func evaluate(_ request: Request, state: TabGuardState, now: Date) -> PopupDecision {
        guard isShieldEnabled(request.pageHost) else { return .allowNewTab(background: false) }

        let host = request.url?.host
        if LoginHosts.contains(host) {
            return .allowNewTab(background: false)
        }
        if adHosts.contains(host: host) {
            return .block(reason: "рекламный адрес \(host ?? "")")
        }
        let scheme = request.url?.scheme?.lowercased() ?? ""
        guard ["http", "https", "blob"].contains(scheme) else {
            return .block(reason: "окно без адреса или со странной схемой «\(scheme)»")
        }
        guard request.fromMainFrame else {
            return .block(reason: "окно из iframe")
        }
        guard let tapped = state.recentLinkURL(now, within: Self.tapWindow) else {
            return .block(reason: "окно без касания ссылки")
        }
        if request.isLinkActivation {
            return .allowNewTab(background: false)
        }
        // window.open с адресом той самой ссылки, которой коснулись (сайт открывает её сам).
        if Self.sameDocument(tapped, request.url) {
            return .allowNewTab(background: false)
        }
        return .block(reason: "window.open после касания")
    }

    /// Совпадают ли адреса без учёта #фрагмента.
    static func sameDocument(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        func strip(_ url: URL) -> String {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.fragment = nil
            return c?.string ?? url.absoluteString
        }
        return strip(a) == strip(b)
    }
}

/// Доступ к sourceFrame без падения: в некоторых случаях WebKit отдаёт nil, хотя в Swift
/// свойство объявлено необязательным.
@MainActor
enum GuardFrames {
    static func sourceFrame(of action: WKNavigationAction) -> WKFrameInfo? {
        let selector = #selector(getter: WKNavigationAction.sourceFrame)
        guard action.responds(to: selector) else { return nil }
        return action.perform(selector)?.takeUnretainedValue() as? WKFrameInfo
    }

    static func targetFrame(of action: WKNavigationAction) -> WKFrameInfo? {
        let selector = #selector(getter: WKNavigationAction.targetFrame)
        guard action.responds(to: selector) else { return nil }
        return action.perform(selector)?.takeUnretainedValue() as? WKFrameInfo
    }
}

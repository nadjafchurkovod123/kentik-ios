import WebKit

/// Единственное место, где создаются WKWebView.
///
/// Обычные вкладки живут в `WKWebsiteDataStore.default()`.
/// Все вкладки инкогнито одной «сессии» делят один `WKWebsiteDataStore.nonPersistent()`;
/// когда закрывается последняя вкладка инкогнито, сессия сбрасывается (TabManager зовёт
/// `resetIncognitoSession()`), и следующая вкладка инкогнито получает чистое хранилище.
@MainActor
enum WebViewFactory {

    private static var incognitoStore: WKWebsiteDataStore?

    /// Хранилище текущей сессии инкогнито (создаётся при первом обращении).
    static var currentIncognitoDataStore: WKWebsiteDataStore {
        if let store = incognitoStore { return store }
        let store = WKWebsiteDataStore.nonPersistent()
        incognitoStore = store
        return store
    }

    /// Забыть хранилище инкогнито: куки, кэш и прочее исчезают вместе с ним.
    static func resetIncognitoSession() {
        incognitoStore = nil
        // Выключатели щита, сделанные в инкогнито, уходят вместе с сессией.
        BlockingSettings.shared.resetIncognitoOverrides()
    }

    /// Создаёт веб-вью для вкладки.
    /// - Parameter popupConfiguration: конфигурация из `createWebViewWith` — WebKit требует
    ///   вернуть веб-вью ровно с ней. Контроллер скриптов в ней заменяем на свой (хуки
    ///   блокировщика и защиты ставятся заново), остальное наследуется от открывателя.
    static func makeWebView(for tab: Tab, popupConfiguration: WKWebViewConfiguration? = nil) -> WKWebView {
        let configuration: WKWebViewConfiguration
        if let popupConfiguration {
            configuration = popupConfiguration
            // Свой контроллер для окна: иначе оно делит его с вкладкой-открывателем, и
            // выключение щита на сайте окна сняло бы правила и у открывателя.
            // WebKit проверяет только связь с открывателем, а не контроллер.
            let userContent = WKUserContentController()
            configuration.userContentController = userContent
            ContentBlocker.shared.install(on: userContent, host: nil, incognito: tab.isIncognito)
            GuardInstaller.install(on: configuration, tab: tab)
        } else {
            configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = tab.isIncognito
                ? currentIncognitoDataStore
                : WKWebsiteDataStore.default()
            configuration.allowsInlineMediaPlayback = true
            configuration.allowsPictureInPictureMediaPlayback = true
            // Полноэкранный режим для плееров (Fullscreen API) — нужен сайтам с сериалами.
            configuration.preferences.isElementFullscreenEnabled = true
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.defaultWebpagePreferences.preferredContentMode = .mobile

            let userContent = WKUserContentController()
            configuration.userContentController = userContent

            // Хуки модулей Blocking и Guard.
            ContentBlocker.shared.install(on: userContent, host: nil, incognito: tab.isIncognito)
            GuardInstaller.install(on: configuration, tab: tab)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isOpaque = false
        webView.backgroundColor = Theme.background
        webView.scrollView.backgroundColor = Theme.background
#if DEBUG
        webView.isInspectable = true
#endif
        return webView
    }
}

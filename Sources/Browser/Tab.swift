import WebKit

/// Вкладка браузера. Владеет своим WKWebView (создаёт его WebViewFactory) и следит за его
/// состоянием; об изменениях сообщает через `TabManager.tabDidUpdate(_:)`.
@MainActor
final class Tab {

    let id = UUID()
    let isIncognito: Bool
    weak var manager: TabManager?
    /// Вкладка, из которой открыта эта (window.open / target=_blank).
    weak var opener: Tab?

    private(set) var webView: WKWebView!
    private let webDelegate = TabWebDelegate()
    private var observations: [NSKeyValueObservation] = []
    /// Адрес, который попросили открыть, пока WebKit ещё не сообщил свой.
    private var requestedURL: URL?

    private(set) var title = ""
    private(set) var progress: Double = 0
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    // Счётчики щита для этой вкладки. Пишет Browser (по решениям PopupGuard/RedirectGuard)
    // и модуль Blocking; UI читает через ShieldControlling.stats(for:).
    var blockedPopups = 0
    var blockedRedirects = 0
    var hiddenElements = 0

    /// Текущий адрес страницы (nil — пустая вкладка, показываем домашний экран).
    var url: URL? { webView.url ?? requestedURL }

    var host: String? { url?.host }

    init(isIncognito: Bool, popupConfiguration: WKWebViewConfiguration? = nil) {
        self.isIncognito = isIncognito
        webView = WebViewFactory.makeWebView(for: self, popupConfiguration: popupConfiguration)
        webDelegate.tab = self
        webView.navigationDelegate = webDelegate
        webView.uiDelegate = webDelegate
        startObserving()
    }

    // MARK: - Навигация

    func load(_ url: URL) {
        requestedURL = url
        webView.load(URLRequest(url: url))
        notifyChanged()
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    /// Освобождает веб-вью при закрытии вкладки.
    func tearDown() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    /// Сообщить менеджеру (и через него UI), что состояние вкладки изменилось.
    func notifyChanged() {
        manager?.tabDidUpdate(self)
    }

    // MARK: - KVO

    private func startObserving() {
        guard let webView else { return }
        let handler: (WKWebView) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.syncFromWebView() }
        }
        observations = [
            webView.observe(\.title, options: [.new]) { wv, _ in handler(wv) },
            webView.observe(\.url, options: [.new]) { wv, _ in handler(wv) },
            webView.observe(\.estimatedProgress, options: [.new]) { wv, _ in handler(wv) },
            webView.observe(\.isLoading, options: [.new]) { wv, _ in handler(wv) },
            webView.observe(\.canGoBack, options: [.new]) { wv, _ in handler(wv) },
            webView.observe(\.canGoForward, options: [.new]) { wv, _ in handler(wv) },
        ]
    }

    private func syncFromWebView() {
        guard let webView else { return }
        title = webView.title ?? ""
        progress = webView.estimatedProgress
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if webView.url != nil { requestedURL = nil }
        notifyChanged()
    }
}

import WebKit

/// Делегаты навигации и UI одной вкладки. Решения о всплывающих окнах и переходах
/// принимают PopupGuard и RedirectGuard; здесь — только исполнение и счётчики.
@MainActor
final class TabWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {

    weak var tab: Tab?

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let tab else {
            decisionHandler(.allow)
            return
        }
        let policy = RedirectGuard.shared.decide(navigationAction: navigationAction, tab: tab)
        if policy == .cancel {
            tab.blockedRedirects += 1
            tab.notifyChanged()
        } else if navigationAction.targetFrame?.isMainFrame ?? true {
            // Щит по настройкам сайта, куда идём: ставит/снимает списки до загрузки страницы.
            ContentBlocker.shared.prepareNavigation(of: webView, to: navigationAction.request.url)
        }
        decisionHandler(policy)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab?.notifyChanged()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab { ContentBlocker.shared.pageDidFinishLoading(tab: tab) }
        tab?.notifyChanged()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logNavigationError(error)
        tab?.notifyChanged()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        logNavigationError(error)
        tab?.notifyChanged()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Процесс страницы упал (обычно нехватка памяти): решает вкладка — видимую
        // перезагрузить сразу, фоновую при показе, частые падения не повторять.
        tab?.webContentProcessDidTerminate()
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let tab, let manager = tab.manager else { return nil }
        let decision = PopupGuard.shared.decide(
            createWebViewWith: configuration,
            navigationAction: navigationAction,
            windowFeatures: windowFeatures,
            tab: tab
        )
        switch decision {
        case .block(let reason):
            tab.blockedPopups += 1
            tab.notifyChanged()
            NSLog("[Kentik] всплывающее окно заблокировано: %@", reason)
            return nil
        case .allowNewTab(let background):
            let newTab = manager.addTab(
                incognito: tab.isIncognito,
                select: !background,
                opener: tab,
                popupConfiguration: configuration
            )
            return newTab.webView
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab else { return }
        tab.manager?.close(tab)
    }

    // MARK: - Вспомогательное

    private func logNavigationError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        NSLog("[Kentik] ошибка загрузки: %@", nsError.localizedDescription)
    }
}

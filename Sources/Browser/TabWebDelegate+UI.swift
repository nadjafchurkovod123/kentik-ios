import WebKit
import UIKit

/// Диалог JavaScript (alert / confirm / prompt), который показывает UI.
enum JSDialog {
    case alert(message: String, done: () -> Void)
    case confirm(message: String, done: (Bool) -> Void)
    case prompt(message: String, defaultText: String?, done: (String?) -> Void)

    /// Ответ «по умолчанию», если диалог не показан.
    func dismissSilently() {
        switch self {
        case .alert(_, let done): done()
        case .confirm(_, let done): done(false)
        case .prompt(_, _, let done): done(nil)
        }
    }
}

/// Что умеет интерфейс браузера для вкладок (реализует BrowserViewController).
@MainActor
protocol BrowserUIHost: AnyObject {
    func showToast(_ text: String, symbol: String?)
    /// Меню долгого нажатия на ссылку.
    func linkMenu(for url: URL, from tab: Tab) -> UIMenu
    func presentDialog(_ dialog: JSDialog, origin: String, tab: Tab)
}

/// Точка доступа к интерфейсу из модулей без ссылки на контроллер.
@MainActor
enum BrowserUI {
    static weak var host: BrowserUIHost?
}

// MARK: - Диалоги, меню ссылок, загрузки

extension TabWebDelegate {

    /// Диалоги показываем только для выбранной вкладки и только от самой страницы
    /// (или фрейма того же сайта) — рекламные фреймы и фоновые вкладки молчат.
    private func allowsDialog(from frame: WKFrameInfo, tab: Tab) -> Bool {
        guard tab.manager?.selectedTab === tab else { return false }
        if frame.isMainFrame { return true }
        let frameHost = displayHost(frame.securityOrigin.host)
        return !frameHost.isEmpty && frameHost == displayHost(tab.host)
    }

    private func present(_ dialog: JSDialog, frame: WKFrameInfo) {
        guard let tab, allowsDialog(from: frame, tab: tab), let host = BrowserUI.host else {
            dialog.dismissSilently()
            return
        }
        let origin = displayHost(frame.securityOrigin.host)
        host.presentDialog(dialog, origin: origin.isEmpty ? displayHost(tab.host) : origin, tab: tab)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        present(.alert(message: message, done: completionHandler), frame: frame)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        present(.confirm(message: message, done: completionHandler), frame: frame)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        present(.prompt(message: prompt, defaultText: defaultText, done: completionHandler), frame: frame)
    }

    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        guard let url = elementInfo.linkURL, let tab, let host = BrowserUI.host else {
            completionHandler(nil)
            return
        }
        let menu = host.linkMenu(for: url, from: tab)
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
        completionHandler(configuration)
    }

    // MARK: Загрузки

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // Скачиваем только то, что открывает сама страница (главный фрейм):
        // рекламные фреймы не должны подсовывать файлы.
        guard navigationResponse.isForMainFrame else {
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
            return
        }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }
}

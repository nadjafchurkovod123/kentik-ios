import UIKit
import WebKit

/// Восстановление после падения процесса страницы (обычно нехватка памяти): не больше
/// `limit` автоматических перезагрузок за `window` секунд, иначе — не зацикливаться.
struct CrashRecovery: Equatable {
    static let limit = 2
    static let window: TimeInterval = 30

    private(set) var crashes: [Date] = []
    /// Страницу надо перезагрузить, когда вкладка окажется на экране.
    var needsReload = false
    /// Падает слишком часто — сами больше не перезагружаем, ждём пользователя.
    private(set) var gaveUp = false

    mutating func recordCrash(at now: Date) {
        crashes = crashes.filter { now.timeIntervalSince($0) <= Self.window } + [now]
        gaveUp = crashes.count > Self.limit
        needsReload = !gaveUp
    }

    mutating func reset() {
        crashes.removeAll()
        gaveUp = false
        needsReload = false
    }
}

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
    /// Падения процесса страницы и отложенная перезагрузка.
    private(set) var crashRecovery = CrashRecovery()
    /// Адрес последней открывшейся (commit) страницы главного фрейма: история пишется с этого
    /// момента, не дожидаясь конца загрузки (сайты с плеерами и рекламой «грузятся» долго).
    private(set) var committedURL: URL?
    /// Только что закончился полноэкранный режим WebKit (браузер проверит, что веб-вью на месте).
    var fullscreenJustEnded = false
    private var lastFullscreenState: WKWebView.FullscreenState = .notInFullscreen

    // Счётчики щита для этой вкладки. Пишет Browser (по решениям PopupGuard/RedirectGuard)
    // и модуль Blocking; UI читает через ShieldControlling.stats(for:).
    var blockedPopups = 0
    var blockedRedirects = 0
    /// Спрятано правилами блокировщика на текущей странице (оценка, пересчитывает Blocking).
    var hiddenByRules = 0
    /// Убрано защитой Guard (слои поверх плеера, стены «выключите AdBlock») за жизнь вкладки.
    var hiddenByGuard = 0
    /// Страница, на которой уже показана плашка о блокировке (BlockedNoticeBar): одна на страницу.
    var noticeShownForPage: String?
    /// Всего спрятанных элементов — то, что показывает шторка щита.
    var hiddenElements: Int { hiddenByRules + hiddenByGuard }

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
        // Адрес открывает сам пользователь (адресная строка, «Открыть») — защита не мешает.
        RedirectGuard.shared.noteAppNavigation(to: url, tab: self)
        webView.load(URLRequest(url: url))
        notifyChanged()
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func stopLoading() { webView.stopLoading() }

    /// Обновить (пользователь): заодно сбрасывает счётчик падений.
    func reload() {
        crashRecovery.reset()
        if webView.url != nil {
            webView.reload()
        } else if let requestedURL {
            load(requestedURL)
        }
    }

    /// Адрес, который вкладка собирается открыть (восстановление сессии через interactionState).
    func noteRequestedURL(_ url: URL) {
        if webView.url == nil { requestedURL = url }
    }

    // MARK: - Падение процесса страницы

    /// Процесс страницы убит системой. Видимую вкладку перезагружаем сразу (если приложение
    /// на экране), фоновые — когда их покажут; при частых падениях — не зацикливаемся.
    func webContentProcessDidTerminate(at now: Date = Date()) {
        crashRecovery.recordCrash(at: now)
        let visible = manager?.selectedTab === self && UIApplication.shared.applicationState == .active
        if visible {
            if crashRecovery.gaveUp {
                showCrashNotice()
            } else {
                reloadAfterCrashIfNeeded()
            }
        }
        notifyChanged()
    }

    /// Перезагрузить упавшую страницу, если это ещё не сделано (показ вкладки, возврат из фона).
    func reloadAfterCrashIfNeeded() {
        if crashRecovery.gaveUp {
            showCrashNotice()
            return
        }
        guard crashRecovery.needsReload else { return }
        crashRecovery.needsReload = false
        if webView.url != nil {
            webView.reload()
        } else if let requestedURL {
            // Процесс упал до первой загрузки: reload() ничего бы не сделал.
            load(requestedURL)
        }
    }

    private func showCrashNotice() {
        BrowserUI.host?.showToast("Странице не хватает памяти. Нажмите «Обновить», чтобы попробовать ещё раз",
                                  symbol: "exclamationmark.triangle")
    }

    /// Освобождает веб-вью при закрытии вкладки.
    func tearDown() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    /// В главном фрейме открылась новая страница (didCommit).
    func noteCommitted() {
        committedURL = webView.url
        if webView.url != nil { requestedURL = nil }
        notifyChanged()
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
            webView.observe(\.fullscreenState, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let state = wv.fullscreenState
                    if state == .notInFullscreen, self.lastFullscreenState != .notInFullscreen {
                        self.fullscreenJustEnded = true
                    }
                    self.lastFullscreenState = state
                    DiagProbe.event("fullscreen", ["state": state.rawValue])
                    self.notifyChanged()
                }
            },
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

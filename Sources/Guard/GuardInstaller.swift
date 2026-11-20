import WebKit

/// Хук фабрики веб-вью: ставит защиту от всплывающих окон и перенаправлений в конфигурацию.
///
///  * javaScriptCanOpenWindowsAutomatically = false — окна без жеста пользователя WebKit
///    не открывает вовсе;
///  * скриплеты (Scriptlets) во все фреймы до загрузки страницы: один в мире страницы,
///    другой в отдельном мире Kentik;
///  * обработчики сообщений скриплетов (касания, заблокированные окна, скрытые оверлеи).
///
/// Настройки щита (общий выключатель и сайты-исключения) вшиты в текст скриплетов; при их
/// смене (Notification.Name.shieldSettingsChanged) скриплеты пересобираются во всех
/// веб-вью, а UI перезагружает вкладку.
@MainActor
enum GuardInstaller {

    /// Отдельный мир скриптов Kentik: страница не видит его переменных и обработчиков.
    static let world = WKContentWorld.world(name: "KentikGuard")
    static let isolatedHandlerName = "kentikGuard"
    static let pageHandlerName = "kentikPopup"

    private static let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private static var observer: NSObjectProtocol?
    private static var cached: (config: Scriptlets.Config, scripts: [WKUserScript])?

    /// Откуда брать настройки щита (в тестах подменяется).
    static var settingsProvider: @MainActor () -> Scriptlets.Config = {
        let settings = BlockingSettings.shared
        return Scriptlets.Config(enabled: settings.isEnabledGlobally,
                                 disabledHosts: settings.disabledHosts.sorted())
    }

    static func install(on configuration: WKWebViewConfiguration, tab: Tab) {
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        prepareOnce()

        let controller = configuration.userContentController
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)

        let handler = GuardMessageHandler(tab: tab)
        controller.add(handler, contentWorld: world, name: isolatedHandlerName)
        controller.add(handler, contentWorld: .page, name: pageHandlerName)
        currentScripts().forEach(controller.addUserScript)
    }

    /// Пересобрать скриплеты во всех живых веб-вью (после смены настроек щита).
    static func refreshScripts() {
        let scripts = currentScripts()
        for controller in controllers.allObjects {
            let others = controller.userScripts.filter { !$0.source.hasPrefix(Scriptlets.marker) }
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
            scripts.forEach(controller.addUserScript)
        }
    }

    /// Скриплеты для текущих настроек (кэшируются, пока настройки не меняются).
    static func currentScripts() -> [WKUserScript] {
        let config = settingsProvider()
        if let cached, cached.config == config { return cached.scripts }
        let scripts = [
            WKUserScript(source: Scriptlets.pageSource(config), injectionTime: .atDocumentStart,
                         forMainFrameOnly: false, in: .page),
            WKUserScript(source: Scriptlets.isolatedSource(config), injectionTime: .atDocumentStart,
                         forMainFrameOnly: false, in: world),
        ]
        cached = (config, scripts)
        return scripts
    }

    private static func prepareOnce() {
        guard observer == nil else { return }
        AdHosts.shared.add(GuardTestHooks.extraAdHosts)
        AdHosts.shared.preload()
        observer = NotificationCenter.default.addObserver(
            forName: .shieldSettingsChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { refreshScripts() }
        }
    }
}

/// Принимает сообщения скриплетов. Вкладку ищет по веб-вью сообщения: всплывающие окна
/// делят контроллер (и этот обработчик) с вкладкой-открывателем.
@MainActor
final class GuardMessageHandler: NSObject, WKScriptMessageHandler {

    private weak var tab: Tab?

    init(tab: Tab) {
        self.tab = tab
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let tab = resolveTab(for: message.webView) else { return }
        let isolated = message.world == GuardInstaller.world

        switch type {
        case "tap" where isolated:
            let link = (body["link"] as? String).flatMap { URL(string: $0) }
            GuardState.shared.recordTap(on: tab, link: link)
        case "popup":
            let url = (body["url"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            tab.blockedPopups += 1
            tab.notifyChanged()
            NSLog("[Kentik] скриплет погасил окно (%@): %@", body["why"] as? String ?? "?", url?.absoluteString ?? "")
            BlockedNoticeBar.show(.popup, url: url, on: tab)
        case "hijack" where isolated:
            tab.blockedPopups += 1
            tab.notifyChanged()
        case "overlay" where isolated:
            tab.hiddenByGuard += 1
            tab.notifyChanged()
        default:
            break
        }
    }

    private func resolveTab(for webView: WKWebView?) -> Tab? {
        guard let tab else { return nil }
        guard let webView else { return tab }
        if tab.webView === webView { return tab }
        return tab.manager?.tabs.first { $0.webView === webView }
    }
}

import WebKit

/// Хук фабрики веб-вью: ставит скриптлеты защиты (до загрузки страницы) в конфигурацию.
///
/// Каркас: ничего не ставит. Агент Guard добавит WKUserScript из Scriptlets и,
/// при необходимости, обработчики сообщений.
@MainActor
enum GuardInstaller {

    static func install(on configuration: WKWebViewConfiguration, tab: Tab) {
        for source in Scriptlets.all {
            let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            configuration.userContentController.addUserScript(script)
        }
    }
}

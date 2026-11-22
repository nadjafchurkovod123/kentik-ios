import WebKit

/// Получатель событий о вкладках (обычно BrowserViewController).
@MainActor
protocol TabManagerDelegate: AnyObject {
    func tabManager(_ manager: TabManager, didSelect tab: Tab?, previous: Tab?)
    func tabManager(_ manager: TabManager, didUpdate tab: Tab)
    func tabManagerDidChangeTabs(_ manager: TabManager)
}

/// Список вкладок (обычных и инкогнито) и выбранная вкладка.
@MainActor
final class TabManager {

    private(set) var tabs: [Tab] = []
    private(set) var selectedTab: Tab?
    weak var delegate: TabManagerDelegate?

    var normalTabs: [Tab] { tabs.filter { !$0.isIncognito } }
    var incognitoTabs: [Tab] { tabs.filter { $0.isIncognito } }
    var hasIncognitoTabs: Bool { tabs.contains { $0.isIncognito } }

    /// Открывает новую вкладку.
    /// - Parameters:
    ///   - url: что загрузить (nil — пустая вкладка с домашним экраном).
    ///   - incognito: вкладка инкогнито (общее непостоянное хранилище сессии).
    ///   - select: сразу сделать выбранной (false — открыть в фоне).
    ///   - opener: вкладка-открыватель; новая встанет сразу за ней.
    ///   - popupConfiguration: конфигурация из `createWebViewWith` (только для всплывающих окон).
    @discardableResult
    func addTab(
        url: URL? = nil,
        incognito: Bool = false,
        select: Bool = true,
        opener: Tab? = nil,
        popupConfiguration: WKWebViewConfiguration? = nil
    ) -> Tab {
        let tab = Tab(isIncognito: incognito, popupConfiguration: popupConfiguration)
        tab.manager = self
        tab.opener = opener
        if let opener, let index = tabs.firstIndex(where: { $0 === opener }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        delegate?.tabManagerDidChangeTabs(self)
        if select { self.select(tab) }
        if let url { tab.load(url) }
        return tab
    }

    func select(_ tab: Tab) {
        guard tabs.contains(where: { $0 === tab }), selectedTab !== tab else { return }
        let previous = selectedTab
        selectedTab = tab
        delegate?.tabManager(self, didSelect: tab, previous: previous)
    }

    /// Закрывает вкладку. Если это была последняя вкладка инкогнито — сессия инкогнито
    /// сбрасывается целиком.
    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: index)
        tab.tearDown()
        if !tab.isIncognito { SessionStore.shared.noteNormalTabClosed() }
        if tab.isIncognito && !hasIncognitoTabs {
            WebViewFactory.resetIncognitoSession()
        }
        if selectedTab === tab {
            let next: Tab?
            // Следующая — из того же режима: закрыв обычную вкладку, не попадаем в инкогнито
            // (и наоборот), пока в режиме есть вкладки.
            let sameMode = tabs.enumerated().filter { $0.element.isIncognito == tab.isIncognito }
            if let opener = tab.opener, tabs.contains(where: { $0 === opener }) {
                next = opener
            } else if tabs.isEmpty {
                next = nil
            } else if !sameMode.isEmpty {
                next = (sameMode.first { $0.offset >= index } ?? sameMode.last)?.element
            } else {
                next = tabs[min(index, tabs.count - 1)]
            }
            selectedTab = next
            delegate?.tabManager(self, didSelect: next, previous: tab)
        }
        delegate?.tabManagerDidChangeTabs(self)
    }

    /// Закрыть все вкладки инкогнито (и тем самым стереть сессию).
    func closeAllIncognitoTabs() {
        incognitoTabs.forEach { close($0) }
    }

    func tabDidUpdate(_ tab: Tab) {
        delegate?.tabManager(self, didUpdate: tab)
    }
}

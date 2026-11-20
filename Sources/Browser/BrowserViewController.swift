import UIKit
import WebKit

/// Главный экран: адресная строка сверху, страница выбранной вкладки, панель кнопок снизу.
final class BrowserViewController: UIViewController {

    let tabManager: TabManager
    private let shield: ShieldControlling = ShieldController.shared

    private let addressBar = AddressBarView()
    private let webContainer = UIView()
    private let homeView = HomeView()
    private let toolbar = UIToolbar()
    private let toolbarBackground = UIView()

    private var backItem: UIBarButtonItem!
    private var forwardItem: UIBarButtonItem!
    private var reloadItem: UIBarButtonItem!
    private var shieldItem: UIBarButtonItem!
    private var tabsItem: UIBarButtonItem!

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        tabManager.delegate = self
        buildLayout()
        buildToolbar()
        addressBar.textField.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shieldSettingsChanged),
            name: .shieldSettingsChanged,
            object: nil
        )

        updateChrome()
        // Сначала готовим правила блокировщика, потом открываем первую вкладку —
        // иначе первая страница загрузится без них.
        ContentBlocker.shared.prepare { [weak self] in
            self?.openInitialTab()
        }
    }

    private func openInitialTab() {
        guard tabManager.tabs.isEmpty else { return }
        tabManager.addTab(url: TestHooks.startURL, incognito: false)
    }

    // MARK: - Разметка

    private func buildLayout() {
        [webContainer, toolbarBackground, toolbar, addressBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        homeView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(homeView)
        webContainer.backgroundColor = Theme.background
        webContainer.clipsToBounds = true
        toolbarBackground.backgroundColor = Theme.bar

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            addressBar.topAnchor.constraint(equalTo: view.topAnchor),
            addressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            addressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            toolbar.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: safe.bottomAnchor),

            toolbarBackground.topAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbarBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            webContainer.topAnchor.constraint(equalTo: addressBar.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            homeView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            homeView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            homeView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            homeView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])
    }

    private func buildToolbar() {
        let appearance = UIToolbarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = Theme.bar
        appearance.shadowColor = .clear
        toolbar.standardAppearance = appearance
        toolbar.scrollEdgeAppearance = appearance
        toolbar.compactAppearance = appearance
        toolbar.tintColor = Theme.violet

        backItem = barItem("chevron.backward", label: "Назад", id: "backButton", action: #selector(goBack))
        forwardItem = barItem("chevron.forward", label: "Вперёд", id: "forwardButton", action: #selector(goForward))
        reloadItem = barItem("arrow.clockwise", label: "Обновить", id: "reloadButton", action: #selector(reloadOrStop))

        shieldItem = UIBarButtonItem(title: nil, image: UIImage(systemName: "shield.lefthalf.filled"), primaryAction: nil, menu: nil)
        shieldItem.accessibilityIdentifier = "shieldButton"
        shieldItem.accessibilityLabel = "Блокировка рекламы"

        tabsItem = UIBarButtonItem(title: nil, image: UIImage(systemName: "square.on.square"), primaryAction: nil, menu: nil)
        tabsItem.accessibilityIdentifier = "tabsButton"
        tabsItem.accessibilityLabel = "Вкладки"

        toolbar.items = [
            backItem, .flexibleSpace(),
            forwardItem, .flexibleSpace(),
            shieldItem, .flexibleSpace(),
            reloadItem, .flexibleSpace(),
            tabsItem,
        ]
    }

    private func barItem(_ symbol: String, label: String, id: String, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain, target: self, action: action)
        item.accessibilityLabel = label
        item.accessibilityIdentifier = id
        return item
    }

    // MARK: - Меню щита и вкладок
    // Временные меню каркаса; полноценный UI щита и переключатель вкладок делает агент UI.

    private func makeShieldMenu() -> UIMenu {
        let host = tabManager.selectedTab?.host
        let globalOn = shield.isEnabledGlobally

        let global = UIAction(
            title: "Блокировка рекламы",
            image: UIImage(systemName: "shield.lefthalf.filled"),
            state: globalOn ? .on : .off
        ) { [weak self] _ in
            guard let self else { return }
            self.shield.isEnabledGlobally.toggle()
        }

        var siteAttributes: UIMenuElement.Attributes = []
        if host == nil || !globalOn { siteAttributes.insert(.disabled) }
        let siteOn = shield.isEnabled(forHost: host)
        let site = UIAction(
            title: host.map { "На сайте \($0)" } ?? "На этом сайте",
            image: UIImage(systemName: "globe"),
            attributes: siteAttributes,
            state: siteOn ? .on : .off
        ) { [weak self] _ in
            guard let self, let host else { return }
            self.shield.setEnabled(!self.shield.isEnabled(forHost: host), forHost: host)
        }

        var children: [UIMenuElement] = [global, site]
        if let tab = tabManager.selectedTab {
            let stats = shield.stats(for: tab)
            let info = UIAction(
                title: "Окон: \(stats.blockedPopups) · переходов: \(stats.blockedRedirects)",
                attributes: .disabled
            ) { _ in }
            children.append(UIMenu(title: "", options: .displayInline, children: [info]))
        }
        return UIMenu(title: "Щит Kentik", children: children)
    }

    private func makeTabsMenu() -> UIMenu {
        let newTab = UIAction(title: "Новая вкладка", image: UIImage(systemName: "plus.square")) { [weak self] _ in
            self?.tabManager.addTab(incognito: false)
            self?.addressBar.textField.becomeFirstResponder()
        }
        let newIncognito = UIAction(title: "Новая вкладка инкогнито", image: UIImage(systemName: "eye.slash")) { [weak self] _ in
            self?.tabManager.addTab(incognito: true)
            self?.addressBar.textField.becomeFirstResponder()
        }
        let close = UIAction(
            title: "Закрыть вкладку",
            image: UIImage(systemName: "xmark.square"),
            attributes: tabManager.selectedTab == nil ? [.disabled] : [.destructive]
        ) { [weak self] _ in
            self?.closeSelectedTab()
        }
        let count = tabManager.tabs.count
        return UIMenu(title: "Вкладок: \(count)", children: [newTab, newIncognito, close])
    }

    private func closeSelectedTab() {
        guard let tab = tabManager.selectedTab else { return }
        tabManager.close(tab)
        if tabManager.tabs.isEmpty {
            tabManager.addTab(incognito: false)
        }
    }

    // MARK: - Действия

    @objc private func goBack() { tabManager.selectedTab?.goBack() }
    @objc private func goForward() { tabManager.selectedTab?.goForward() }

    @objc private func reloadOrStop() {
        guard let tab = tabManager.selectedTab else { return }
        if tab.isLoading { tab.stopLoading() } else { tab.reload() }
    }

    @objc private func shieldSettingsChanged() {
        // После переключения щита перезагружаем текущую страницу, чтобы правила применились.
        if let tab = tabManager.selectedTab, tab.url != nil { tab.reload() }
        updateChrome()
    }

    private func open(_ url: URL) {
        if let tab = tabManager.selectedTab {
            tab.load(url)
        } else {
            tabManager.addTab(url: url, incognito: false)
        }
    }

    // MARK: - Обновление интерфейса

    private func show(_ tab: Tab?, replacing previous: Tab?) {
        previous?.webView.removeFromSuperview()
        if let webView = tab?.webView {
            webView.translatesAutoresizingMaskIntoConstraints = false
            webContainer.insertSubview(webView, belowSubview: homeView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
                webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            ])
        }
        updateChrome()
    }

    private func updateChrome() {
        let tab = tabManager.selectedTab
        backItem.isEnabled = tab?.canGoBack ?? false
        forwardItem.isEnabled = tab?.canGoForward ?? false
        let loading = tab?.isLoading ?? false
        reloadItem.image = UIImage(systemName: loading ? "xmark" : "arrow.clockwise")
        reloadItem.accessibilityLabel = loading ? "Остановить" : "Обновить"

        addressBar.setIncognito(tab?.isIncognito ?? false)
        addressBar.setProgress(tab?.progress ?? 0, loading: loading)
        let title = tab?.title ?? ""
        addressBar.titleLabel.text = title.isEmpty ? (tab?.isIncognito == true ? "Инкогнито" : "Kentik") : title
        if !addressBar.textField.isEditing {
            addressBar.textField.text = displayText(for: tab?.url)
        }
        homeView.isHidden = tab?.url != nil

        let shieldOn = shield.isEnabled(forHost: tab?.host)
        shieldItem.image = UIImage(systemName: shieldOn ? "shield.lefthalf.filled" : "shield.slash")
        shieldItem.menu = makeShieldMenu()
        tabsItem.menu = makeTabsMenu()
    }

    private func displayText(for url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        if let host = url.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return url.absoluteString
    }
}

// MARK: - TabManagerDelegate

extension BrowserViewController: TabManagerDelegate {
    func tabManager(_ manager: TabManager, didSelect tab: Tab?, previous: Tab?) {
        show(tab, replacing: previous)
    }

    func tabManager(_ manager: TabManager, didUpdate tab: Tab) {
        if tab === manager.selectedTab { updateChrome() }
    }

    func tabManagerDidChangeTabs(_ manager: TabManager) {
        updateChrome()
    }
}

// MARK: - UITextFieldDelegate

extension BrowserViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        if let url = tabManager.selectedTab?.url, url.absoluteString != "about:blank" {
            textField.text = url.absoluteString
        }
        DispatchQueue.main.async { textField.selectAll(nil) }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let url = AddressParser.url(from: textField.text ?? "") {
            open(url)
        }
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        updateChrome()
    }
}

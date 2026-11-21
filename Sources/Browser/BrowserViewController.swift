import UIKit
import WebKit
import SwiftUI

/// Главный экран. По умолчанию всё управление внизу, под большим пальцем:
/// строка адреса (с щитом) и ряд кнопок. Адресную строку можно поднять наверх в настройках.
final class BrowserViewController: UIViewController {

    let tabManager: TabManager
    private let shield: ShieldControlling = ShieldController.shared
    private let settings = AppSettings.shared

    let addressBar = AddressBarView()
    private let toolbarView = BrowserToolbarView()
    private let topStack = UIStackView()
    private let bottomStack = UIStackView()
    private let topBackground = UIView()
    private let bottomBackground = UIView()
    private let topLine = UIView()
    private let bottomLine = UIView()
    private let webContainer = UIView()
    private let homeView = HomeView()
    private let suggestions = SuggestionsView()
    private var lockView: IncognitoLockView?
    private weak var tabSwitcher: TabSwitcherViewController?
    private weak var shieldSheet: ShieldSheetViewController?

    private var bottomToSafeArea: NSLayoutConstraint!
    private var bottomToKeyboard: NSLayoutConstraint!
    private var position: AddressBarPosition = .bottom
    private var lightStatusBar = true
    private var homeState: Bool?   // nil — домашний экран скрыт, иначе — показан для инкогнито?

    private var lastHistoryURL: [UUID: URL] = [:]
    private var zoomHost: [UUID: String] = [:]
    private var dialogCount: [UUID: Int] = [:]
    private var dialogsMuted: Set<UUID> = []
    private var pendingExternalURLs: [URL] = []
    private var isReady = false
    private lazy var addressPan = UIPanGestureRecognizer(target: self, action: #selector(addressPanned(_:)))

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { lightStatusBar ? .lightContent : .darkContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        tabManager.delegate = self
        BrowserUI.host = self
        buildLayout()
        wireActions()
        applyAddressBarPosition()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(shieldSettingsChanged), name: .shieldSettingsChanged, object: nil)
        center.addObserver(self, selector: #selector(appSettingsChanged), name: .appSettingsChanged, object: nil)
        center.addObserver(self, selector: #selector(lockChanged), name: .incognitoLockChanged, object: nil)

        updateChrome()
        // Сначала готовим правила блокировщика, потом открываем первую вкладку —
        // иначе первая страница загрузится без них.
        ContentBlocker.shared.prepare { [weak self] in
            self?.openInitialTab()
        }
    }

    // MARK: - Первая вкладка и восстановление

    private func openInitialTab() {
        isReady = true
        if tabManager.tabs.isEmpty {
            if let url = TestHooks.startURL {
                tabManager.addTab(url: url, incognito: false)
            } else if !TestHooks.skipsSession, let session = SessionStore.shared.load(), !session.tabs.isEmpty {
                restore(session)
            } else {
                tabManager.addTab(incognito: false)
            }
        }
        // С этого момента сессию можно сохранять (раньше пустой снимок затёр бы файл).
        SessionStore.shared.markRestored()
        let external = pendingExternalURLs
        pendingExternalURLs.removeAll()
        external.forEach(openExternal)
    }

    /// Восстановить обычные вкладки. Грузится только выбранная, остальные — при первом показе.
    private func restore(_ session: SavedSession) {
        var restored: [Tab] = []
        for saved in session.tabs {
            let tab = tabManager.addTab(url: nil, incognito: false, select: false)
            SessionStore.shared.setPending(saved, for: tab)
            restored.append(tab)
        }
        guard !restored.isEmpty else { return }
        let index = min(max(session.selectedIndex, 0), restored.count - 1)
        tabManager.select(restored[index])
    }

    /// Ссылка снаружи (kentik://) — в новой обычной вкладке.
    func openExternal(_ url: URL) {
        guard isReady else {
            pendingExternalURLs.append(url)
            return
        }
        let open = { [weak self] in
            guard let self else { return }
            self.tabManager.addTab(url: url, incognito: false)
        }
        if presentedViewController != nil {
            dismiss(animated: false, completion: open)
        } else {
            open()
        }
    }

    /// Показывает ли экран сейчас что-то из инкогнито (для шторки в переключателе приложений).
    var isShowingIncognitoContent: Bool {
        if let switcher = tabSwitcher { return switcher.showingIncognito || (tabManager.selectedTab?.isIncognito ?? false) }
        return tabManager.selectedTab?.isIncognito ?? false
    }

    func saveState() {
        // До восстановления вкладок (блокировщик ещё готовится) сессию не трогаем.
        if isReady { SessionStore.shared.saveNow(tabManager) }
        HistoryStore.shared.saveNow()
    }

    /// Приложение снова на экране: упавшую, пока были в фоне, страницу перезагрузить.
    func didBecomeActive() {
        guard isReady else { return }
        tabManager.selectedTab?.reloadAfterCrashIfNeeded()
    }

    /// Инкогнито заперто Face ID, и на экране вкладка инкогнито: ничего из неё не показываем
    /// (адрес, заголовок, история «назад/вперёд», шторки) и не даём ею пользоваться.
    private var isIncognitoLocked: Bool {
        (tabManager.selectedTab?.isIncognito ?? false) && IncognitoLock.shared.isLocked
    }

    /// Вернулись из фона: если инкогнито заперто и на экране — спросить Face ID.
    func unlockIfNeeded() {
        guard IncognitoLock.shared.isLocked, isShowingIncognitoContent, !IncognitoLock.shared.isAuthenticating else { return }
        IncognitoLock.shared.unlock { _ in }
    }

    // MARK: - Разметка

    private func buildLayout() {
        topStack.axis = .vertical
        bottomStack.axis = .vertical
        bottomStack.addArrangedSubview(toolbarView)

        [topBackground, bottomBackground, webContainer, suggestions, topStack, bottomStack, topLine, bottomLine].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        homeView.translatesAutoresizingMaskIntoConstraints = false
        webContainer.addSubview(homeView)
        webContainer.backgroundColor = Theme.background
        webContainer.clipsToBounds = true
        suggestions.isHidden = true
        suggestions.alpha = 0
        topLine.isUserInteractionEnabled = false
        bottomLine.isUserInteractionEnabled = false

        let safe = view.safeAreaLayoutGuide
        let hairline = 1 / max(UIScreen.main.scale, 1)
        bottomToSafeArea = bottomStack.bottomAnchor.constraint(equalTo: safe.bottomAnchor)
        bottomToKeyboard = bottomStack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        let topEmpty = topStack.heightAnchor.constraint(equalToConstant: 0)
        topEmpty.priority = .defaultLow
        let bottomEmpty = bottomStack.heightAnchor.constraint(equalToConstant: 0)
        bottomEmpty.priority = .defaultLow

        NSLayoutConstraint.activate([
            topBackground.topAnchor.constraint(equalTo: view.topAnchor),
            topBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBackground.bottomAnchor.constraint(equalTo: topStack.bottomAnchor),

            topStack.topAnchor.constraint(equalTo: safe.topAnchor),
            topStack.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            topStack.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            topEmpty,

            webContainer.topAnchor.constraint(equalTo: topStack.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: bottomStack.topAnchor),

            bottomStack.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            bottomStack.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            bottomToSafeArea,
            bottomEmpty,

            bottomBackground.topAnchor.constraint(equalTo: bottomStack.topAnchor),
            bottomBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            topLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topLine.topAnchor.constraint(equalTo: topBackground.bottomAnchor),
            topLine.heightAnchor.constraint(equalToConstant: hairline),

            bottomLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: bottomBackground.topAnchor),
            bottomLine.heightAnchor.constraint(equalToConstant: hairline),

            homeView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            homeView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            homeView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            homeView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),

            suggestions.topAnchor.constraint(equalTo: webContainer.topAnchor),
            suggestions.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            suggestions.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            suggestions.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])
    }

    private func wireActions() {
        addressBar.textField.delegate = self
        addressBar.textField.addTarget(self, action: #selector(addressTextChanged), for: .editingChanged)
        addressBar.reloadButton.addTarget(self, action: #selector(reloadOrStop), for: .touchUpInside)
        addressBar.shieldButton.addTarget(self, action: #selector(presentShield), for: .touchUpInside)
        addressBar.cancelButton.addTarget(self, action: #selector(cancelEditing), for: .touchUpInside)
        addressPan.delegate = self
        addressBar.pill.addGestureRecognizer(addressPan)

        toolbarView.backButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        toolbarView.forwardButton.addTarget(self, action: #selector(goForward), for: .touchUpInside)
        toolbarView.newTabButton.addTarget(self, action: #selector(newTabTapped), for: .touchUpInside)
        toolbarView.tabsButton.addTarget(self, action: #selector(presentTabSwitcher), for: .touchUpInside)

        // Меню собирается при каждом открытии — состояние всегда свежее.
        toolbarView.menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                MainActor.assumeIsolated {
                    completion(self?.mainMenuElements() ?? [])
                }
            },
        ])
        // Долгое нажатие на кнопку вкладок — быстрые действия.
        toolbarView.tabsButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                MainActor.assumeIsolated {
                    completion(self?.tabsMenuElements() ?? [])
                }
            },
        ])

        homeView.onSearchTap = { [weak self] in self?.focusAddressBar() }
        homeView.onOpen = { [weak self] url, background in
            guard let self else { return }
            if background {
                self.tabManager.addTab(url: url, incognito: false, select: false, opener: self.tabManager.selectedTab)
                self.showToast("Открыто в фоне", symbol: "square.on.square")
            } else {
                self.open(url)
            }
        }
        suggestions.onPick = { [weak self] url in
            guard let self else { return }
            self.addressBar.textField.resignFirstResponder()
            self.open(url)
        }
    }

    /// Адресная строка вверху или внизу.
    private func applyAddressBarPosition() {
        position = settings.addressBarPosition
        if addressBar.superview != nil {
            (addressBar.superview as? UIStackView)?.removeArrangedSubview(addressBar)
            addressBar.removeFromSuperview()
        }
        if position == .top {
            topStack.addArrangedSubview(addressBar)
        } else {
            bottomStack.insertArrangedSubview(addressBar, at: 0)
        }
        suggestions.bottomAligned = position == .bottom
        view.layoutIfNeeded()
        updateChrome()
    }

    // MARK: - Меню

    private func mainMenuElements() -> [UIMenuElement] {
        let tab = tabManager.selectedTab
        let incognito = tab?.isIncognito ?? false
        // Запертое инкогнито: действия со страницей (поделиться, копировать, чтение) недоступны.
        let pageURL = isIncognitoLocked ? nil : tab?.url
        let hasPage = pageURL != nil

        let newTab = incognito
            ? UIAction(title: "Новая обычная вкладка", image: UIImage(systemName: "plus.square")) { [weak self] _ in
                self?.newTab(incognito: false)
            }
            : UIAction(title: "Новая вкладка инкогнито", image: UIImage(systemName: "eye.slash")) { [weak self] _ in
                self?.newTab(incognito: true)
            }
        var tabsSection: [UIMenuElement] = [newTab]
        if tabManager.hasIncognitoTabs {
            tabsSection.append(UIAction(title: "Закрыть все вкладки инкогнито", image: UIImage(systemName: "xmark.square"),
                                        attributes: .destructive) { [weak self] _ in
                self?.closeAllIncognito()
            })
        }

        let pageAttributes: UIMenuElement.Attributes = hasPage ? [] : [.disabled]
        let find = UIAction(title: "Найти на странице", image: UIImage(systemName: "doc.text.magnifyingglass"),
                            attributes: pageAttributes) { [weak self] _ in
            self?.findInPage()
        }
        let reader = UIAction(title: "Режим чтения", image: UIImage(systemName: "doc.plaintext"),
                              attributes: pageAttributes) { [weak self] _ in
            self?.openReader()
        }
        let desktop = tab?.isDesktopMode ?? false
        let desktopAction = UIAction(title: desktop ? "Мобильная версия" : "Версия для ПК",
                                     image: UIImage(systemName: desktop ? "iphone" : "desktopcomputer"),
                                     attributes: pageAttributes) { [weak tab] _ in
            guard let tab else { return }
            tab.setDesktopMode(!tab.isDesktopMode)
        }

        let zoom = Double(tab?.webView.pageZoom ?? 1)
        let zoomOut = UIAction(title: "Мельче", image: UIImage(systemName: "minus.magnifyingglass"),
                               attributes: hasPage ? [.keepsMenuPresented] : [.disabled]) { [weak self] _ in
            self?.changeZoom(up: false)
        }
        let zoomReset = UIAction(title: "\(Int((zoom * 100).rounded()))%", image: UIImage(systemName: "textformat.size"),
                                 attributes: pageAttributes) { [weak self] _ in
            self?.resetZoom()
        }
        let zoomIn = UIAction(title: "Крупнее", image: UIImage(systemName: "plus.magnifyingglass"),
                              attributes: hasPage ? [.keepsMenuPresented] : [.disabled]) { [weak self] _ in
            self?.changeZoom(up: true)
        }
        let zoomMenu = UIMenu(title: "Масштаб страницы", options: .displayInline, children: [zoomOut, zoomReset, zoomIn])
        zoomMenu.preferredElementSize = .small

        let share = UIAction(title: "Поделиться", image: UIImage(systemName: "square.and.arrow.up"),
                             attributes: pageAttributes) { [weak self] _ in
            if let url = pageURL { self?.share(url) }
        }
        let copy = UIAction(title: "Копировать ссылку", image: UIImage(systemName: "link"),
                            attributes: pageAttributes) { [weak self] _ in
            if let url = pageURL {
                UIPasteboard.general.url = url
                self?.showToast("Ссылка скопирована", symbol: "link")
            }
        }

        let history = UIAction(title: "История", image: UIImage(systemName: "clock")) { [weak self] _ in
            self?.presentHistory()
        }
        let downloads = UIAction(title: "Загрузки", image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
            self?.presentDownloads()
        }
        let settingsAction = UIAction(title: "Настройки", image: UIImage(systemName: "gearshape")) { [weak self] _ in
            self?.presentSettings()
        }

        return [
            UIMenu(title: "", options: .displayInline, children: tabsSection),
            UIMenu(title: "", options: .displayInline, children: [find, reader, desktopAction]),
            zoomMenu,
            UIMenu(title: "", options: .displayInline, children: [share, copy]),
            UIMenu(title: "", options: .displayInline, children: [history, downloads, settingsAction]),
        ]
    }

    private func tabsMenuElements() -> [UIMenuElement] {
        let incognito = tabManager.selectedTab?.isIncognito ?? false
        var items: [UIMenuElement] = [
            UIAction(title: "Новая вкладка", image: UIImage(systemName: "plus.square")) { [weak self] _ in
                self?.newTab(incognito: false)
            },
            UIAction(title: "Новая вкладка инкогнито", image: UIImage(systemName: "eye.slash")) { [weak self] _ in
                self?.newTab(incognito: true)
            },
        ]
        if tabManager.selectedTab != nil {
            items.append(UIAction(title: incognito ? "Закрыть вкладку инкогнито" : "Закрыть вкладку",
                                  image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                self?.closeSelectedTab()
            })
        }
        return items
    }

    // MARK: - Действия

    @objc private func goBack() {
        guard !isIncognitoLocked else { return }
        tabManager.selectedTab?.goBack()
    }

    @objc private func goForward() {
        guard !isIncognitoLocked else { return }
        tabManager.selectedTab?.goForward()
    }

    @objc private func reloadOrStop() {
        guard let tab = tabManager.selectedTab, !isIncognitoLocked else { return }
        if tab.isLoading { tab.stopLoading() } else { tab.reload() }
    }

    @objc private func newTabTapped() {
        newTab(incognito: tabManager.selectedTab?.isIncognito ?? false)
    }

    private func newTab(incognito: Bool) {
        if incognito, IncognitoLock.shared.isLocked {
            // Новая вкладка инкогнито при запертом инкогнито — сначала Face ID, как «+»
            // в переключателе вкладок; отмена — ничего не открывается.
            IncognitoLock.shared.unlock { [weak self] ok in
                guard ok, let self else { return }
                self.tabManager.addTab(incognito: true)
                self.focusAddressBar()
            }
            return
        }
        tabManager.addTab(incognito: incognito)
        focusAddressBar()
    }

    func focusAddressBar() {
        guard !isIncognitoLocked else { return }
        addressBar.textField.becomeFirstResponder()
    }

    @objc private func cancelEditing() {
        addressBar.textField.resignFirstResponder()
    }

    private func closeSelectedTab() {
        guard let tab = tabManager.selectedTab else { return }
        tabManager.close(tab)
        if tabManager.tabs.isEmpty {
            tabManager.addTab(incognito: false)
        }
    }

    func closeAllIncognito() {
        tabManager.closeAllIncognitoTabs()
        if tabManager.tabs.isEmpty {
            tabManager.addTab(incognito: false)
        } else if tabManager.selectedTab == nil, let last = tabManager.normalTabs.last {
            tabManager.select(last)
        }
        showToast("Вкладки инкогнито закрыты", symbol: "eye.slash")
    }

    private func open(_ url: URL) {
        if let tab = tabManager.selectedTab {
            SessionStore.shared.forget(tab)
            tab.load(url)
        } else {
            tabManager.addTab(url: url, incognito: false)
        }
    }

    private func share(_ url: URL) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = toolbarView.menuButton
        present(activity, animated: true)
    }

    private func findInPage() {
        guard let webView = tabManager.selectedTab?.webView else { return }
        webView.isFindInteractionEnabled = true
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    private func changeZoom(up: Bool) {
        guard let tab = tabManager.selectedTab, tab.url != nil else { return }
        let next = SiteZoom.step(from: Double(tab.webView.pageZoom), up: up)
        tab.webView.pageZoom = CGFloat(next)
        SiteZoom.shared.setZoom(next, for: tab.host, incognito: tab.isIncognito)
        showToast("Масштаб \(Int((next * 100).rounded()))%", symbol: "textformat.size")
    }

    private func resetZoom() {
        guard let tab = tabManager.selectedTab else { return }
        tab.webView.pageZoom = 1
        SiteZoom.shared.setZoom(1, for: tab.host, incognito: tab.isIncognito)
    }

    private func openReader() {
        guard let tab = tabManager.selectedTab, tab.url != nil, !isIncognitoLocked else { return }
        ReaderExtractor.extract(from: tab.webView) { [weak self] article in
            guard let self else { return }
            guard let article else {
                self.showToast("Режим чтения недоступен на этой странице", symbol: "doc.plaintext")
                return
            }
            let reader = ReaderViewController(article: article)
            reader.onOpenLink = { [weak self] url in self?.open(url) }
            let nav = Self.darkNavigation(reader)
            nav.modalPresentationStyle = .pageSheet
            nav.sheetPresentationController?.detents = [.large()]
            nav.sheetPresentationController?.prefersGrabberVisible = true
            self.present(nav, animated: true)
        }
    }

    // MARK: - Экраны

    @objc private func presentShield() {
        guard !isIncognitoLocked else { return }
        let sheet = ShieldSheetViewController(shield: shield, tab: tabManager.selectedTab)
        sheet.onOpenSettings = { [weak self] in self?.presentSettings() }
        shieldSheet = sheet
        present(sheet, animated: true)
    }

    @objc private func presentTabSwitcher() {
        if addressBar.textField.isFirstResponder { addressBar.textField.resignFirstResponder() }
        let incognito = tabManager.selectedTab?.isIncognito ?? false
        let switcher = TabSwitcherViewController(tabManager: tabManager, incognito: incognito)
        switcher.onFinish = { [weak self] newTab in
            guard let self else { return }
            self.updateChrome()
            if newTab { self.focusAddressBar() }
        }
        tabSwitcher = switcher
        if let tab = tabManager.selectedTab {
            captureSnapshot(of: tab) { [weak switcher] in switcher?.reloadSnapshots() }
        }
        present(switcher, animated: true)
    }

    func presentSettings() {
        let model = SettingsModel(shield: shield)
        model.incognitoCount = { [weak self] in self?.tabManager.incognitoTabs.count ?? 0 }
        model.refresh()
        let host = UIHostingController(rootView: SettingsView(model: model))
        host.view.backgroundColor = Theme.background
        host.overrideUserInterfaceStyle = .dark
        model.dismiss = { [weak host] in host?.dismiss(animated: true) }
        model.closeAllIncognito = { [weak self] in self?.closeAllIncognito() }
        model.openHistory = { [weak self, weak host] in
            host?.dismiss(animated: true) { self?.presentHistory() }
        }
        model.openDownloads = { [weak self, weak host] in
            host?.dismiss(animated: true) { self?.presentDownloads() }
        }
        host.modalPresentationStyle = .pageSheet
        present(host, animated: true)
    }

    func presentHistory() {
        weak var host: UIHostingController<HistoryView>?
        let historyView = HistoryView(
            store: .shared,
            onOpen: { [weak self] url in
                host?.dismiss(animated: true) { self?.open(url) }
            },
            onDone: { host?.dismiss(animated: true) }
        )
        let controller = UIHostingController(rootView: historyView)
        controller.view.backgroundColor = Theme.background
        controller.overrideUserInterfaceStyle = .dark
        controller.modalPresentationStyle = .pageSheet
        host = controller
        present(controller, animated: true)
    }

    func presentDownloads() {
        let nav = Self.darkNavigation(DownloadsViewController(style: .insetGrouped))
        present(nav, animated: true)
    }

    static func darkNavigation(_ root: UIViewController) -> UINavigationController {
        let nav = UINavigationController(rootViewController: root)
        nav.overrideUserInterfaceStyle = .dark
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = Theme.bar
        appearance.titleTextAttributes = [.foregroundColor: Theme.text]
        appearance.shadowColor = .clear
        nav.navigationBar.standardAppearance = appearance
        nav.navigationBar.scrollEdgeAppearance = appearance
        nav.navigationBar.compactAppearance = appearance
        nav.navigationBar.tintColor = Theme.violet
        return nav
    }

    // MARK: - Уведомления

    @objc private func shieldSettingsChanged() {
        // После переключения щита перезагружаем текущую страницу, чтобы правила применились.
        if let tab = tabManager.selectedTab, tab.url != nil { tab.reload() }
        updateChrome()
    }

    @objc private func appSettingsChanged() {
        if settings.addressBarPosition != position { applyAddressBarPosition() }
        updateChrome()
    }

    @objc private func lockChanged() {
        if IncognitoLock.shared.isLocked {
            endIncognitoEditing()
        }
        if IncognitoLock.shared.isLocked, isShowingIncognitoContent {
            // Запираем: убрать всё, что показывает инкогнито поверх страницы (чтение, щит,
            // вкладки), и ввод адреса — замок закрывает только область страницы.
            // Переключатель вкладок не закрываем: он сам прячет раздел «Инкогнито» за замком.
            if addressBar.textField.isFirstResponder { addressBar.textField.resignFirstResponder() }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            if let presented = presentedViewController, presented !== tabSwitcher { dismiss(animated: false) }
        }
        updateLockOverlay(autoPrompt: false)
        updateChrome()
    }

    // MARK: - Показ вкладки

    private func show(_ tab: Tab?, replacing previous: Tab?) {
        if let previous {
            captureSnapshot(of: previous, completion: nil)
            previous.webView.removeFromSuperview()
            setPageHidden(false, for: previous)
        }
        if let tab {
            SessionStore.shared.loadPendingIfNeeded(tab)
            tab.reloadAfterCrashIfNeeded()
            let webView: WKWebView = tab.webView
            prepare(webView)
            webView.translatesAutoresizingMaskIntoConstraints = false
            webContainer.insertSubview(webView, belowSubview: homeView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
                webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            ])
            applyZoomIfNeeded(tab)
        }
        updateChrome()
        updateLockOverlay(autoPrompt: true)
    }

    /// Разовая настройка веб-вью: поиск по странице и «потяни, чтобы обновить».
    /// Признак «уже настроено» — сам refreshControl веб-вью (не адрес объекта: после закрытия
    /// вкладки новая веб-вью может получить тот же адрес в памяти).
    private func prepare(_ webView: WKWebView) {
        guard webView.scrollView.refreshControl == nil else { return }
        webView.isFindInteractionEnabled = true
        let refresh = UIRefreshControl()
        refresh.tintColor = Theme.violet
        refresh.addAction(UIAction { [weak webView] _ in
            webView?.reload()
        }, for: .valueChanged)
        webView.scrollView.refreshControl = refresh
    }

    private func captureSnapshot(of tab: Tab, completion: (() -> Void)?) {
        // Запертую вкладку инкогнито не снимаем: она спрятана, снимок вышел бы пустым,
        // а свежий снимок запертой страницы и не нужен, пока её никому не показывают.
        let locked = tab.isIncognito && IncognitoLock.shared.isLocked
        guard tab.url != nil, tab.webView.window != nil, !locked else {
            completion?()
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: 360)
        tab.webView.takeSnapshot(with: configuration) { image, _ in
            MainActor.assumeIsolated {
                if let image { SnapshotCache.shared.set(image, for: tab) }
                completion?()
            }
        }
    }

    private func applyZoomIfNeeded(_ tab: Tab) {
        let host = displayHost(tab.host)
        guard zoomHost[tab.id] != host else { return }
        zoomHost[tab.id] = host
        let zoom = CGFloat(SiteZoom.shared.zoom(for: host, incognito: tab.isIncognito))
        if abs(tab.webView.pageZoom - zoom) > 0.001 { tab.webView.pageZoom = zoom }
    }

    private func shieldState(for tab: Tab?) -> ShieldState {
        guard shield.isEnabledGlobally else { return .off }
        return shield.isEnabled(forHost: tab?.host, incognito: tab?.isIncognito ?? false) ? .on : .siteOff
    }

    private func updateChrome() {
        let tab = tabManager.selectedTab
        let incognito = tab?.isIncognito ?? false
        let palette = ChromePalette.forIncognito(incognito)
        let loading = tab?.isLoading ?? false

        // Над строкой состояния — цвет темы сайта (если адрес внизу), иначе цвет панели.
        // На домашнем экране — чёрный, как обои.
        var topColor = palette.bar
        if position == .bottom, !incognito, let tab {
            if tab.displayURL == nil {
                topColor = .black
            } else if let theme = tab.webView.themeColor {
                topColor = theme
            }
        }
        topBackground.backgroundColor = topColor
        bottomBackground.backgroundColor = palette.bar
        topLine.backgroundColor = position == .top ? palette.line : .clear
        bottomLine.backgroundColor = palette.line
        view.backgroundColor = palette.background
        webContainer.backgroundColor = palette.background
        suggestions.applyPalette(palette)
        let light = !topColor.isLight
        if light != lightStatusBar {
            lightStatusBar = light
            setNeedsStatusBarAppearanceUpdate()
        }

        // Запертое инкогнито: ни адреса, ни заголовка, ни истории «назад/вперёд».
        let locked = isIncognitoLocked
        addressBar.applyPalette(palette, incognito: incognito)
        addressBar.update(url: locked ? nil : tab?.displayURL, title: locked ? "" : (tab?.title ?? ""), incognito: incognito)
        addressBar.setLoading(loading && !locked, progress: tab?.progress ?? 0)
        var blocked = 0
        if let tab, !locked {
            let stats = shield.stats(for: tab)
            blocked = stats.blockedPopups + stats.blockedRedirects
        }
        addressBar.setShield(shieldState(for: tab), blocked: blocked)
        addressBar.shieldButton.isEnabled = !locked
        addressPan.isEnabled = !locked

        toolbarView.backButton.isEnabled = !locked && (tab?.canGoBack ?? false)
        toolbarView.forwardButton.isEnabled = !locked && (tab?.canGoForward ?? false)
        toolbarView.setTint(Theme.text, incognito: incognito)
        toolbarView.setTabCount(incognito ? tabManager.incognitoTabs.count : tabManager.normalTabs.count)

        let showHome = tab != nil && tab?.displayURL == nil
        homeView.isHidden = !showHome
        let newHomeState: Bool? = showHome ? incognito : nil
        if newHomeState != homeState {
            homeState = newHomeState
            if showHome { homeView.reload(incognito: incognito) }
        }
        if !loading { tab?.webView.scrollView.refreshControl?.endRefreshing() }
        shieldSheet?.refresh()
    }

    /// Запертые вкладки инкогнито не держат клавиатуру: ни поле на странице, ни «Найти на странице».
    /// Спрятанная веб-вью фокус не теряет, и по возвращении из фона iOS вернула бы клавиатуру
    /// (с подсказками автозаполнения для сайта или со словом поиска и числом совпадений),
    /// а набранное ушло бы в спрятанную страницу.
    private func endIncognitoEditing() {
        for tab in tabManager.incognitoTabs {
            guard let webView = tab.webView else { continue }
            if let find = webView.findInteraction, find.isFindNavigatorVisible {
                find.dismissFindNavigator()
            }
            webView.endEditing(true)
        }
    }

    /// Страница под замком не рисуется вовсе и не видна VoiceOver: замок её не прикрывает,
    /// а заменяет (иначе текст страницы оставался бы в дереве доступности под замком).
    private func setPageHidden(_ hidden: Bool, for tab: Tab) {
        tab.webView.isHidden = hidden
        tab.webView.accessibilityElementsHidden = hidden
    }

    private func updateLockOverlay(autoPrompt: Bool) {
        let locked = isIncognitoLocked
        if let tab = tabManager.selectedTab { setPageHidden(locked, for: tab) }
        if locked { endIncognitoEditing() }
        homeView.accessibilityElementsHidden = locked
        if locked {
            if lockView == nil {
                let lock = IncognitoLockView()
                lock.onUnlock = { IncognitoLock.shared.unlock { _ in } }
                lock.translatesAutoresizingMaskIntoConstraints = false
                webContainer.addSubview(lock)
                NSLayoutConstraint.activate([
                    lock.topAnchor.constraint(equalTo: webContainer.topAnchor),
                    lock.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
                    lock.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
                    lock.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
                ])
                lockView = lock
                if autoPrompt, UIApplication.shared.applicationState == .active {
                    IncognitoLock.shared.unlock { _ in }
                }
            }
            webContainer.bringSubviewToFront(lockView!)
        } else if let lockView {
            UIView.animate(withDuration: Theme.mid, animations: { lockView.alpha = 0 }, completion: { _ in
                lockView.removeFromSuperview()
            })
            self.lockView = nil
        }
    }

    // MARK: - Ввод адреса

    private func setAddressEditing(_ editing: Bool) {
        addressBar.setEditing(editing, animated: true)
        if editing {
            bottomToSafeArea.isActive = false
            bottomToKeyboard.isActive = true
            suggestions.update(query: "")
            suggestions.isHidden = false
        } else {
            bottomToKeyboard.isActive = false
            bottomToSafeArea.isActive = true
        }
        UIView.animate(withDuration: Theme.mid, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.toolbarView.isHidden = editing
            self.toolbarView.alpha = editing ? 0 : 1
            self.suggestions.alpha = editing ? 1 : 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            if !self.addressBar.isEditingAddress { self.suggestions.isHidden = true }
        })
    }

    @objc private func addressTextChanged() {
        suggestions.update(query: addressBar.textField.text ?? "")
    }

    // MARK: - Смахивание по адресной строке

    @objc private func addressPanned(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view).x
        switch g.state {
        case .changed:
            addressBar.pill.transform = CGAffineTransform(translationX: t * 0.35, y: 0)
        case .ended, .cancelled:
            let v = g.velocity(in: view).x
            UIView.animate(withDuration: Theme.slow, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
                self.addressBar.pill.transform = .identity
            }
            if g.state == .ended, abs(t) > 50 || abs(v) > 600 {
                switchTab(by: t < 0 ? 1 : -1)
            }
        default:
            break
        }
    }

    /// Соседняя вкладка того же режима (обычная/инкогнито).
    private func switchTab(by offset: Int) {
        guard let current = tabManager.selectedTab else { return }
        let list = current.isIncognito ? tabManager.incognitoTabs : tabManager.normalTabs
        guard let index = list.firstIndex(where: { $0 === current }) else { return }
        let next = index + offset
        guard list.indices.contains(next) else {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            return
        }
        UISelectionFeedbackGenerator().selectionChanged()
        tabManager.select(list[next])
        webContainer.transform = CGAffineTransform(translationX: CGFloat(offset) * 60, y: 0)
        webContainer.alpha = 0.4
        UIView.animate(withDuration: Theme.mid, delay: 0, options: .curveEaseOut) {
            self.webContainer.transform = .identity
            self.webContainer.alpha = 1
        }
    }

    // MARK: - Служебное

    /// История, сессия, масштаб, диалоги — для каждой вкладки при изменении адреса.
    private func trackChanges(of tab: Tab) {
        guard let url = tab.webView.url else { return }
        if lastHistoryURL[tab.id] != url {
            guard !tab.isLoading else { return }
            lastHistoryURL[tab.id] = url
            dialogCount[tab.id] = 0
            dialogsMuted.remove(tab.id)
            HistoryStore.shared.record(url: url, title: tab.title, incognito: tab.isIncognito)
            applyZoomIfNeeded(tab)
            if !tab.isIncognito { SessionStore.shared.scheduleSave(tabManager) }
        } else if !tab.isIncognito {
            HistoryStore.shared.updateTitle(tab.title, for: url)
        }
    }
}

// MARK: - TabManagerDelegate

extension BrowserViewController: TabManagerDelegate {
    func tabManager(_ manager: TabManager, didSelect tab: Tab?, previous: Tab?) {
        show(tab, replacing: previous)
    }

    func tabManager(_ manager: TabManager, didUpdate tab: Tab) {
        trackChanges(of: tab)
        if tab === manager.selectedTab { updateChrome() }
    }

    func tabManagerDidChangeTabs(_ manager: TabManager) {
        let alive = Set(manager.tabs.map(\.id))
        lastHistoryURL = lastHistoryURL.filter { alive.contains($0.key) }
        zoomHost = zoomHost.filter { alive.contains($0.key) }
        dialogCount = dialogCount.filter { alive.contains($0.key) }
        dialogsMuted = dialogsMuted.filter { alive.contains($0) }
        SnapshotCache.shared.prune(keeping: manager.tabs)
        if !manager.hasIncognitoTabs {
            IncognitoLock.shared.reset()
            SiteZoom.shared.resetIncognito()
        }
        SessionStore.shared.scheduleSave(manager)
        updateChrome()
    }
}

// MARK: - BrowserUIHost

extension BrowserViewController: BrowserUIHost {

    func showToast(_ text: String, symbol: String?) {
        ToastView.show(text, symbol: symbol, in: view, above: bottomStack.topAnchor)
    }

    func linkMenu(for url: URL, from tab: Tab) -> UIMenu {
        let incognito = tab.isIncognito
        let background = UIAction(title: "Открыть в фоновой вкладке", image: UIImage(systemName: "square.on.square")) {
            [weak self, weak tab] _ in
            guard let self else { return }
            self.tabManager.addTab(url: url, incognito: incognito, select: false, opener: tab)
            self.showToast("Открыто в фоне", symbol: "square.on.square")
        }
        let newTab = UIAction(title: "Открыть в новой вкладке", image: UIImage(systemName: "plus.square")) {
            [weak self, weak tab] _ in
            self?.tabManager.addTab(url: url, incognito: incognito, select: true, opener: tab)
        }
        let private_ = UIAction(title: "Открыть в инкогнито", image: UIImage(systemName: "eye.slash")) { [weak self] _ in
            self?.tabManager.addTab(url: url, incognito: true, select: true)
        }
        let copy = UIAction(title: "Копировать ссылку", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            UIPasteboard.general.url = url
            self?.showToast("Ссылка скопирована", symbol: "link")
        }
        let share = UIAction(title: "Поделиться", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            self?.share(url)
        }
        let title = url.absoluteString.count > 80 ? String(url.absoluteString.prefix(80)) + "…" : url.absoluteString
        return UIMenu(title: title, children: [
            UIMenu(title: "", options: .displayInline, children: [background, newTab, private_]),
            UIMenu(title: "", options: .displayInline, children: [copy, share]),
        ])
    }

    func presentDialog(_ dialog: JSDialog, origin: String, tab: Tab) {
        let locked = tab.isIncognito && IncognitoLock.shared.isLocked
        guard !dialogsMuted.contains(tab.id), presentedViewController == nil, !locked else {
            dialog.dismissSilently()
            return
        }
        let count = (dialogCount[tab.id] ?? 0) + 1
        dialogCount[tab.id] = count

        let alert: UIAlertController
        switch dialog {
        case .alert(let message, let done):
            alert = UIAlertController(title: origin, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done() })
        case .confirm(let message, let done):
            alert = UIAlertController(title: origin, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in done(false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done(true) })
        case .prompt(let message, let defaultText, let done):
            alert = UIAlertController(title: origin, message: message, preferredStyle: .alert)
            alert.addTextField { field in
                field.text = defaultText
                field.keyboardAppearance = .dark
            }
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in done(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                done(alert?.textFields?.first?.text ?? "")
            })
        }
        // Назойливые страницы: после пары диалогов можно запретить их до ухода со страницы.
        if count > 2 {
            alert.addAction(UIAlertAction(title: "Запретить диалоги на этой странице", style: .destructive) {
                [weak self] _ in
                self?.dialogsMuted.insert(tab.id)
                dialog.dismissSilently()
            })
        }
        alert.view.tintColor = Theme.violet
        present(alert, animated: true)
    }
}

// MARK: - UITextFieldDelegate

extension BrowserViewController: UITextFieldDelegate {
    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        // В запертом инкогнито адрес не показываем и не вводим.
        !isIncognitoLocked
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        if let url = tabManager.selectedTab?.url, url.absoluteString != "about:blank" {
            textField.text = url.absoluteString
        }
        setAddressEditing(true)
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
        setAddressEditing(false)
        updateChrome()
    }
}

// MARK: - UIGestureRecognizerDelegate

extension BrowserViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === addressPan else { return true }
        guard !addressBar.isEditingAddress, !isIncognitoLocked else { return false }
        let v = addressPan.velocity(in: view)
        return abs(v.x) > abs(v.y) * 1.2
    }
}

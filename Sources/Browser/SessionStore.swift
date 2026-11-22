import WebKit

/// Сохранённая вкладка (только обычные — инкогнито не сохраняется никогда).
struct SavedTab: Codable, Equatable {
    var url: URL
    var title: String
    /// WKWebView.interactionState — история «назад/вперёд» вкладки.
    var state: Data?
}

struct SavedSession: Codable, Equatable {
    var tabs: [SavedTab]
    var selectedIndex: Int
}

/// Сохранение и восстановление обычных вкладок между запусками.
/// Файл: Application Support/Kentik/session.json.
@MainActor
final class SessionStore {

    static let shared = SessionStore(fileURL: StoragePaths.appSupport.appendingPathComponent("session.json"))

    private let fileURL: URL
    private var saveScheduled = false
    /// Вкладки уже восстановлены (или решено их не восстанавливать). До этого сохранять
    /// нельзя: пустой снимок (вкладок ещё нет, ждём блокировщик) затёр бы сохранённую сессию.
    private(set) var didRestore = false
    /// Пользователь закрывал обычные вкладки после восстановления — пустой снимок законен.
    private var closedNormalTabs = false
    /// Вкладки, восстановленные из файла, но ещё не загруженные (грузятся при первом показе).
    private var pending: [UUID: SavedTab] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - Ленивое восстановление

    func setPending(_ saved: SavedTab, for tab: Tab) {
        pending[tab.id] = saved
    }

    func pendingTab(for tab: Tab) -> SavedTab? {
        pending[tab.id]
    }

    /// Загрузить восстановленную вкладку, если она ещё не загружена.
    func loadPendingIfNeeded(_ tab: Tab) {
        guard let saved = pending.removeValue(forKey: tab.id) else { return }
        // Адрес на случай, если процесс страницы упадёт до первой загрузки.
        tab.noteRequestedURL(saved.url)
        if let state = saved.state {
            tab.webView.interactionState = state
            // Если состояние не подошло (другая версия WebKit), просто открываем адрес.
            runAfter(1.0) { [weak tab] in
                guard let tab, tab.webView.url == nil, !tab.isLoading else { return }
                tab.load(saved.url)
            }
        } else {
            tab.load(saved.url)
        }
    }

    func forget(_ tab: Tab) {
        pending.removeValue(forKey: tab.id)
    }

    /// Восстановление закончено — с этого момента сессию можно сохранять.
    func markRestored() {
        didRestore = true
    }

    /// Пользователь закрыл обычную вкладку (зовёт TabManager).
    func noteNormalTabClosed() {
        closedNormalTabs = true
    }

    // MARK: - Диск

    func load() -> SavedSession? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SavedSession.self, from: data)
    }

    /// Снимок обычных вкладок.
    func snapshot(of manager: TabManager) -> SavedSession {
        let normal = manager.normalTabs
        var saved: [SavedTab] = []
        var selectedIndex = 0
        for tab in normal {
            if let pendingTab = pending[tab.id] {
                saved.append(pendingTab)
            } else if let url = tab.webView.url, HistoryStore.isRecordable(url) {
                saved.append(SavedTab(url: url, title: tab.title, state: tab.webView.interactionState as? Data))
            } else {
                continue
            }
            if tab === manager.selectedTab { selectedIndex = saved.count - 1 }
        }
        return SavedSession(tabs: saved, selectedIndex: selectedIndex)
    }

    func scheduleSave(_ manager: TabManager) {
        guard !TestHooks.skipsSession, didRestore, !saveScheduled else { return }
        saveScheduled = true
        runAfter(1.5) { [weak self, weak manager] in
            guard let self else { return }
            self.saveScheduled = false
            if let manager { self.saveNow(manager) }
        }
    }

    func saveNow(_ manager: TabManager) {
        guard !TestHooks.skipsSession, didRestore else { return }
        let session = snapshot(of: manager)
        // Пустой снимок не затирает непустой файл, если пользователь сам вкладки не закрывал.
        if session.tabs.isEmpty, !closedNormalTabs, let existing = load(), !existing.tabs.isEmpty {
            return
        }
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

// MARK: - Отображение вкладки (с учётом ещё не загруженных восстановленных)

extension Tab {
    /// Адрес для показа: текущий или сохранённый (если вкладка ещё не загружена).
    var displayURL: URL? {
        url ?? SessionStore.shared.pendingTab(for: self)?.url
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let saved = SessionStore.shared.pendingTab(for: self), !saved.title.isEmpty { return saved.title }
        if let host = displayURL?.host { return displayHost(host) }
        return isIncognito ? "Инкогнито" : "Новая вкладка"
    }

    /// Версия сайта для ПК (подменённый User-Agent).
    var isDesktopMode: Bool { webView.customUserAgent != nil }

    func setDesktopMode(_ desktop: Bool) {
        webView.customUserAgent = desktop ? Tab.desktopUserAgent : nil
        if webView.url != nil { webView.reloadFromOrigin() }
    }

    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
}

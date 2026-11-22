import XCTest
import WebKit
@testable import Kentik

/// Разбор адресной строки: адрес или поиск в Google.
final class AddressParserTests: XCTestCase {

    func testFullURLIsKeptAsIs() {
        XCTAssertEqual(AddressParser.url(from: "https://example.com/a?b=1")?.absoluteString,
                       "https://example.com/a?b=1")
    }

    func testBareDomainGetsHTTPS() {
        XCTAssertEqual(AddressParser.url(from: "  example.com ")?.absoluteString, "https://example.com")
        XCTAssertEqual(AddressParser.url(from: "m.example.org/path")?.absoluteString, "https://m.example.org/path")
    }

    func testLocalAddressesGetHTTP() {
        XCTAssertEqual(AddressParser.url(from: "127.0.0.1:8765/hello.html")?.absoluteString,
                       "http://127.0.0.1:8765/hello.html")
        XCTAssertEqual(AddressParser.url(from: "localhost:3000")?.absoluteString, "http://localhost:3000")
    }

    func testTextBecomesGoogleSearch() throws {
        let url = try XCTUnwrap(AddressParser.url(from: "сериал онлайн c++"))
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(url.path, "/search")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first
        XCTAssertEqual(query?.name, "q")
        XCTAssertEqual(query?.value, "сериал онлайн c++")
        XCTAssertTrue(url.absoluteString.contains("c%2B%2B"))
    }

    func testSingleWordIsSearch() {
        XCTAssertEqual(AddressParser.url(from: "кентик")?.host, "www.google.com")
    }

    func testEmptyInputGivesNil() {
        XCTAssertNil(AddressParser.url(from: "   "))
    }
}

/// Инкогнито: одна непостоянная сессия на все вкладки, сброс после закрытия последней.
@MainActor
final class IncognitoSessionTests: XCTestCase {

    func testIncognitoTabsShareOneNonPersistentStoreUntilLastIsClosed() {
        let manager = TabManager()
        let first = manager.addTab(incognito: true)
        let second = manager.addTab(incognito: true)
        let normal = manager.addTab(incognito: false)

        let session = WebViewFactory.currentIncognitoDataStore
        XCTAssertFalse(session.isPersistent)
        XCTAssertFalse(first.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(second.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(normal.webView.configuration.websiteDataStore.isPersistent)

        manager.close(first)
        XCTAssertTrue(WebViewFactory.currentIncognitoDataStore === session,
                      "пока открыта хоть одна вкладка инкогнито, сессия та же")

        manager.close(second)
        XCTAssertFalse(WebViewFactory.currentIncognitoDataStore === session,
                       "после последней вкладки инкогнито сессия новая")
        XCTAssertEqual(manager.tabs.count, 1)
        manager.close(normal)
    }

    func testShieldSettingsPerHost() {
        let defaults = UserDefaults(suiteName: "KentikTests-\(UUID().uuidString)")!
        let settings = BlockingSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled(forHost: "www.example.com"))
        settings.setEnabled(false, forHost: "WWW.Example.com")
        XCTAssertFalse(settings.isEnabled(forHost: "example.com"))
        XCTAssertTrue(settings.isEnabled(forHost: "other.com"))
        settings.isEnabledGlobally = false
        XCTAssertFalse(settings.isEnabled(forHost: "other.com"))
    }
}

/// История: только обычные вкладки, поиск, частые сайты.
@MainActor
final class HistoryStoreTests: XCTestCase {

    private func makeStore() -> HistoryStore {
        HistoryStore(fileURL: nil, persist: false)
    }

    func testIncognitoAndNonWebURLsAreNotRecorded() {
        let store = makeStore()
        store.record(url: URL(string: "https://secret.example")!, title: "Тайна", incognito: true)
        store.record(url: URL(string: "about:blank")!, title: "", incognito: false)
        store.record(url: URL(string: "data:text/html,hi")!, title: "", incognito: false)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testRecordAggregatesVisitsAndMovesToTop() {
        let store = makeStore()
        let a = URL(string: "https://a.example/page")!
        let b = URL(string: "https://www.b.example/")!
        store.record(url: a, title: "A", incognito: false)
        store.record(url: b, title: "B", incognito: false)
        store.record(url: a, title: "", incognito: false)
        XCTAssertEqual(store.entries.map(\.url), [a, b])
        XCTAssertEqual(store.entries.first?.visitCount, 2)
        XCTAssertEqual(store.entries.first?.title, "A", "пустой заголовок не затирает старый")
        store.updateTitle("A2", for: a)
        XCTAssertEqual(store.entries.first?.title, "A2")
        XCTAssertEqual(store.entries.last?.host, "b.example")
    }

    func testSearchAndTopSites() {
        let store = makeStore()
        for _ in 0..<3 { store.record(url: URL(string: "https://serials.example/ep1")!, title: "Серия 1", incognito: false) }
        store.record(url: URL(string: "https://serials.example/ep2")!, title: "Серия 2", incognito: false)
        store.record(url: URL(string: "https://news.example/")!, title: "Новости", incognito: false)
        XCTAssertEqual(store.search("серия").count, 2)
        XCTAssertEqual(store.search("NEWS").count, 1)
        let top = store.topSites(limit: 5)
        XCTAssertEqual(top.first?.host, "serials.example")
        XCTAssertEqual(top.first?.url.path, "/ep1")
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(store.topSites(limit: 5, excludingHosts: ["serials.example"]).map(\.host), ["news.example"])
        XCTAssertEqual(store.suggestions(for: "news", limit: 3).first?.host, "news.example")
        store.removeAll()
        XCTAssertTrue(store.entries.isEmpty)
    }
}

/// Мелочи интерфейса: поисковики, kentik://, масштаб, имена загрузок, плитки.
@MainActor
final class UIModelTests: XCTestCase {

    override func tearDown() {
        AddressParser.searchBase = SearchEngine.google.searchBase
        AddressParser.searchQueryName = SearchEngine.google.queryName
        super.tearDown()
    }

    func testSearchEngines() throws {
        let defaults = UserDefaults(suiteName: "KentikTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.searchEngine, .google)
        XCTAssertEqual(settings.addressBarPosition, .bottom)
        XCTAssertTrue(settings.incognitoFaceID, "Face ID для инкогнито по умолчанию включено (1.0.2)")

        settings.searchEngine = .yandex
        let url = try XCTUnwrap(AddressParser.url(from: "кентик браузер"))
        XCTAssertEqual(url.host, "yandex.ru")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.name, "text")

        settings.searchEngine = .duckduckgo
        XCTAssertEqual(AddressParser.url(from: "кентик")?.host, "duckduckgo.com")
        settings.searchEngine = .bing
        XCTAssertEqual(AddressParser.url(from: "кентик")?.host, "www.bing.com")
    }

    func testKentikURLs() {
        XCTAssertEqual(KentikURL.target(from: URL(string: "kentik://open?url=https%3A%2F%2Fexample.com%2Fa")!)?.absoluteString,
                       "https://example.com/a")
        XCTAssertEqual(KentikURL.target(from: URL(string: "kentik://example.com/path")!)?.absoluteString,
                       "https://example.com/path")
        XCTAssertEqual(KentikURL.target(from: URL(string: "kentik:https://example.org")!)?.absoluteString,
                       "https://example.org")
        XCTAssertNil(KentikURL.target(from: URL(string: "https://example.com")!))
    }

    func testZoomSteps() {
        XCTAssertEqual(SiteZoom.step(from: 1, up: true), 1.1)
        XCTAssertEqual(SiteZoom.step(from: 1, up: false), 0.85)
        XCTAssertEqual(SiteZoom.step(from: 2, up: true), 2)
        XCTAssertEqual(SiteZoom.step(from: 0.5, up: false), 0.5)

        let zoom = SiteZoom(defaults: UserDefaults(suiteName: "KentikTests-\(UUID().uuidString)")!)
        zoom.setZoom(1.25, for: "www.Example.com", incognito: false)
        XCTAssertEqual(zoom.zoom(for: "example.com", incognito: false), 1.25)
        zoom.setZoom(1.5, for: "example.com", incognito: true)
        XCTAssertEqual(zoom.zoom(for: "example.com", incognito: true), 1.5)
        XCTAssertEqual(zoom.zoom(for: "example.com", incognito: false), 1.25, "инкогнито не пишет на диск")
        zoom.resetIncognito()
        XCTAssertEqual(zoom.zoom(for: "example.com", incognito: true), 1.25)
    }

    func testUniqueDownloadNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = DownloadManager.uniqueURL(in: dir, for: "серия.mp4")
        XCTAssertEqual(first.lastPathComponent, "серия.mp4")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        XCTAssertEqual(DownloadManager.uniqueURL(in: dir, for: "серия.mp4").lastPathComponent, "серия (2).mp4")
        XCTAssertEqual(DownloadManager.uniqueURL(in: dir, for: "a/b:c").lastPathComponent, "a_b_c")
    }

    /// Загрузка из запертого инкогнито: сообщение поверх замка без имени файла.
    func testDownloadToastHidesNameUnderIncognitoLock() {
        XCTAssertEqual(DownloadManager.toastText(.started, fileName: "тайна.pdf", hideName: false), "Загрузка: тайна.pdf")
        XCTAssertEqual(DownloadManager.toastText(.saved, fileName: "тайна.pdf", hideName: false), "Сохранено: тайна.pdf")
        let started = DownloadManager.toastText(.started, fileName: "тайна.pdf", hideName: true)
        let saved = DownloadManager.toastText(.saved, fileName: "тайна.pdf", hideName: true)
        XCTAssertFalse(started.contains("тайна"), started)
        XCTAssertFalse(saved.contains("тайна"), saved)
    }

    func testTilesPinnedFirstAndHiddenSkipped() {
        let defaults = UserDefaults(suiteName: "KentikTests-\(UUID().uuidString)")!
        let history = HistoryStore(fileURL: nil, persist: false)
        for _ in 0..<2 { history.record(url: URL(string: "https://often.example/")!, title: "Часто", incognito: false) }
        history.record(url: URL(string: "https://rare.example/")!, title: "Редко", incognito: false)
        let tiles = TileStore(defaults: defaults, history: history)
        XCTAssertEqual(tiles.tiles().map(\.host), ["often.example", "rare.example"])

        tiles.pin(HomeTile(url: URL(string: "https://rare.example/")!, title: "Редко"))
        XCTAssertEqual(tiles.tiles().map(\.host), ["rare.example", "often.example"])
        XCTAssertTrue(tiles.tiles().first?.pinned ?? false)

        tiles.remove(HomeTile(url: URL(string: "https://often.example/")!, title: "Часто"))
        XCTAssertEqual(tiles.tiles().map(\.host), ["rare.example"])
    }

    func testSessionSnapshotSkipsIncognito() {
        let manager = TabManager()
        let normal = manager.addTab(incognito: false)
        let secret = manager.addTab(incognito: true)
        let store = SessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString).json"))
        store.setPending(SavedTab(url: URL(string: "https://kept.example/")!, title: "Kept", state: nil), for: normal)
        store.setPending(SavedTab(url: URL(string: "https://secret.example/")!, title: "S", state: nil), for: secret)
        let snapshot = store.snapshot(of: manager)
        XCTAssertEqual(snapshot.tabs.map(\.url.host), ["kept.example"])
        manager.close(normal)
        manager.close(secret)
    }
}

/// Сохранение сессии и падения процесса страницы.
@MainActor
final class SessionAndCrashTests: XCTestCase {

    func testEmptySnapshotNeverWipesSavedSessionBeforeRestoreOrWithoutClosing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = SavedSession(tabs: [SavedTab(url: URL(string: "https://kept.example/")!, title: "Kept", state: nil)],
                                 selectedIndex: 0)
        try JSONEncoder().encode(saved).write(to: url)

        let store = SessionStore(fileURL: url)
        let manager = TabManager()   // вкладок ещё нет: блокировщик готовится
        store.saveNow(manager)
        XCTAssertEqual(store.load(), saved, "до восстановления сессию не трогаем")

        store.markRestored()
        store.saveNow(manager)
        XCTAssertEqual(store.load(), saved, "пустой снимок не затирает сохранённые вкладки")

        store.noteNormalTabClosed()
        store.saveNow(manager)
        XCTAssertEqual(store.load()?.tabs.count, 0, "пользователь закрыл вкладки — пустая сессия законна")
    }

    func testCrashRecoveryStopsLooping() {
        var recovery = CrashRecovery()
        let start = Date(timeIntervalSince1970: 5_000)
        recovery.recordCrash(at: start)
        XCTAssertTrue(recovery.needsReload)
        XCTAssertFalse(recovery.gaveUp)
        recovery.needsReload = false
        recovery.recordCrash(at: start.addingTimeInterval(5))
        XCTAssertTrue(recovery.needsReload, "второе падение — ещё одна попытка")
        recovery.recordCrash(at: start.addingTimeInterval(10))
        XCTAssertTrue(recovery.gaveUp, "третье падение за 30 с — больше не перезагружаем")
        XCTAssertFalse(recovery.needsReload)

        // Через минуту — снова можно.
        recovery.recordCrash(at: start.addingTimeInterval(100))
        XCTAssertFalse(recovery.gaveUp)
        XCTAssertTrue(recovery.needsReload)
        recovery.reset()
        XCTAssertEqual(recovery, CrashRecovery())
    }

    func testBackgroundTabCrashReloadsOnlyWhenShown() {
        let manager = TabManager()
        let visible = manager.addTab(incognito: false)
        let background = manager.addTab(incognito: false, select: false)
        XCTAssertTrue(manager.selectedTab === visible)
        background.webContentProcessDidTerminate()
        XCTAssertTrue(background.crashRecovery.needsReload, "фоновая вкладка ждёт показа")
        background.reloadAfterCrashIfNeeded()
        XCTAssertFalse(background.crashRecovery.needsReload)
        manager.close(background)
        manager.close(visible)
    }
}

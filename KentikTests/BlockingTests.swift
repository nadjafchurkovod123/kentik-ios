import XCTest
import WebKit
@testable import Kentik

/// Манифест списков фильтров: разбор, проверка, выбор варианта, сравнение версий.
final class FilterListManifestTests: XCTestCase {

    private let sha = String(repeating: "ab", count: 32)

    private func manifestJSON(schema: Int = 1, version: String = "202611201230",
                              entries: [[String: Any]]? = nil) -> Data {
        let lists = entries ?? [
            ["id": "ads", "variant": "s26", "file": "ads.s26.202611201230.json.deflate",
             "sha256": sha, "bytes": 10, "rules": 140000, "title": "Реклама"],
            ["id": "ads", "variant": "s16", "file": "ads.s16.202611201230.json.deflate",
             "sha256": sha, "bytes": 10, "rules": 139000],
            ["id": "privacy-2", "variant": "s16", "file": "privacy-2.s16.202611201230.json.deflate",
             "sha256": sha, "bytes": 10, "rules": 5000],
        ]
        let object: [String: Any] = ["schema": schema, "version": version, "generated": "2026-11-20T12:30:00Z",
                                     "converter": "SafariConverterLib v4.3.1", "lists": lists,
                                     "sources": [["id": "easylist"]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testParsesManifestAndIgnoresUnknownFields() throws {
        let manifest = try FilterListManifest.parse(manifestJSON())
        XCTAssertEqual(manifest.version, "202611201230")
        XCTAssertEqual(manifest.lists.count, 3)
        XCTAssertEqual(manifest.lists[0].title, "Реклама")
        XCTAssertEqual(manifest.lists[0].rules, 140000)
    }

    func testVariantSelection() throws {
        let manifest = try FilterListManifest.parse(manifestJSON())
        XCTAssertEqual(manifest.entries(for: "s26").map(\.id), ["ads"])
        XCTAssertEqual(manifest.entries(for: "s16").map(\.id), ["ads", "privacy-2"])

        let only16 = try FilterListManifest.parse(manifestJSON(entries: [
            ["id": "ads", "variant": "s16", "file": "ads.s16.json.deflate", "sha256": sha],
        ]))
        XCTAssertEqual(only16.entries(for: "s26").count, 1, "на iOS 26 подходят и списки s16")
        let only26 = try FilterListManifest.parse(manifestJSON(entries: [
            ["id": "ads", "variant": "s26", "file": "ads.s26.json.deflate", "sha256": sha],
        ]))
        XCTAssertTrue(only26.entries(for: "s16").isEmpty, "на старых iOS списки s26 не годятся")
    }

    func testRejectsBadManifests() {
        XCTAssertThrowsError(try FilterListManifest.parse(manifestJSON(schema: 2)))
        XCTAssertThrowsError(try FilterListManifest.parse(manifestJSON(version: "latest")))
        XCTAssertThrowsError(try FilterListManifest.parse(manifestJSON(entries: [])))
        XCTAssertThrowsError(try FilterListManifest.parse(manifestJSON(entries: [
            ["id": "ads", "variant": "s26", "file": "../../evil.json", "sha256": sha],
        ])), "путь с .. недопустим")
        XCTAssertThrowsError(try FilterListManifest.parse(manifestJSON(entries: [
            ["id": "ads", "variant": "s26", "file": "ads.json.deflate", "sha256": "1234"],
        ])), "sha256 должен быть 64 hex")
        XCTAssertThrowsError(try FilterListManifest.parse(manifestJSON(entries: [
            ["id": "Ads Big", "variant": "s26", "file": "ads.json.deflate", "sha256": sha],
        ])))
        XCTAssertThrowsError(try FilterListManifest.parse(Data("не json".utf8)))
    }

    func testVersionComparison() {
        XCTAssertTrue(FilterListManifest.isVersion("202611211200", newerThan: "202611201230"))
        XCTAssertFalse(FilterListManifest.isVersion("202611201230", newerThan: "202611201230"))
        XCTAssertFalse(FilterListManifest.isVersion("202611190000", newerThan: "202611201230"))
        XCTAssertTrue(FilterListManifest.isVersion("202611201230", newerThan: nil))
        XCTAssertTrue(FilterListManifest.isVersion("202611201230", newerThan: "dev"))
        XCTAssertTrue(FilterListManifest.isVersion("1000000000000", newerThan: "999999999999"))
    }

    func testStoreIdentifierIsContentAddressed() throws {
        let manifest = try FilterListManifest.parse(manifestJSON())
        let id = manifest.lists[0].storeIdentifier
        XCTAssertTrue(id.hasPrefix(FilterListManifest.identifierPrefix))
        XCTAssertTrue(id.contains(String(sha.prefix(16))))
        XCTAssertNotEqual(manifest.lists[0].storeIdentifier, manifest.lists[1].storeIdentifier)
    }

    @MainActor
    func testChecksumVerification() throws {
        let data = Data("правила".utf8)
        let digest = FilterListUpdater.sha256Hex(data)
        XCTAssertEqual(digest.count, 64)
        let good = FilterListManifest.Entry(id: "ads", variant: "s26", title: nil, file: "a", sha256: digest,
                                            bytes: data.count, rules: nil)
        XCTAssertNoThrow(try FilterListUpdater.verify(data, entry: good))
        let wrongSHA = FilterListManifest.Entry(id: "ads", variant: "s26", title: nil, file: "a",
                                                sha256: String(repeating: "0", count: 64), bytes: nil, rules: nil)
        XCTAssertThrowsError(try FilterListUpdater.verify(data, entry: wrongSHA))
        let wrongSize = FilterListManifest.Entry(id: "ads", variant: "s26", title: nil, file: "a", sha256: digest,
                                                 bytes: 1, rules: nil)
        XCTAssertThrowsError(try FilterListUpdater.verify(data, entry: wrongSize))
    }

    func testDeflatedListRoundTrip() throws {
        let json = #"[{"trigger":{"url-filter":"/ads/"},"action":{"type":"block"}}]"#
        let packed = try (Data(json.utf8) as NSData).compressed(using: .zlib) as Data
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kentik-\(UUID().uuidString).deflate")
        try packed.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try FilterLists.loadJSON(from: url), json)
    }
}

/// Регистрируемый домен (приближение eTLD+1) для выключателя «на сайте».
final class DomainMatcherTests: XCTestCase {

    func testRegistrableDomain() {
        XCTAssertEqual(DomainMatcher.registrableDomain(of: "WWW.Example.com"), "example.com")
        XCTAssertEqual(DomainMatcher.registrableDomain(of: "m.kinogo.ru"), "kinogo.ru")
        XCTAssertEqual(DomainMatcher.registrableDomain(of: "a.b.c.example.org."), "example.org")
        XCTAssertEqual(DomainMatcher.registrableDomain(of: "news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(DomainMatcher.registrableDomain(of: "shop.site.com.ru"), "site.com.ru")
        XCTAssertEqual(DomainMatcher.registrableDomain(of: "user.github.io"), "user.github.io")
        XCTAssertEqual(DomainMatcher.registrableDomain(of: "kino.ucoz.ru"), "kino.ucoz.ru")
        XCTAssertEqual(DomainMatcher.registrableDomain(of: "bucket.s3.amazonaws.com"), "bucket.s3.amazonaws.com")
        XCTAssertEqual(DomainMatcher.registrableDomain(of: "example.com"), "example.com")
        XCTAssertEqual(DomainMatcher.registrableDomain(of: "www.example"), "example")
    }

    func testAddressesAndSingleLabels() {
        XCTAssertEqual(DomainMatcher.registrableDomain(of: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(DomainMatcher.registrableDomain(of: "192.168.1.20"), "192.168.1.20")
        XCTAssertEqual(DomainMatcher.registrableDomain(of: "localhost"), "localhost")
        XCTAssertEqual(DomainMatcher.registrableDomain(of: "::1"), "::1")
        XCTAssertFalse(DomainMatcher.isIPAddress("1.2.3.999"))
        XCTAssertTrue(DomainMatcher.isIPAddress("10.0.0.1"))
    }

    func testHostBelongsToDomain() {
        XCTAssertTrue(DomainMatcher.host("m.kinogo.ru", belongsTo: "kinogo.ru"))
        XCTAssertTrue(DomainMatcher.host("kinogo.ru", belongsTo: "kinogo.ru"))
        XCTAssertFalse(DomainMatcher.host("notkinogo.ru", belongsTo: "kinogo.ru"))
        XCTAssertFalse(DomainMatcher.host("kinogo.ru.evil.com", belongsTo: "kinogo.ru"))
    }
}

/// Выключатели щита и то, какие списки реально стоят на контроллере веб-вью.
@MainActor
final class ShieldTogglesTests: XCTestCase {

    private func makeSettings() -> BlockingSettings {
        BlockingSettings(defaults: UserDefaults(suiteName: "KentikTests-\(UUID().uuidString)")!)
    }

    func testPerSiteOffCoversWholeRegistrableDomain() {
        let settings = makeSettings()
        settings.setEnabled(false, forHost: "www.kinogo.ru")
        XCTAssertFalse(settings.isEnabled(forHost: "kinogo.ru"))
        XCTAssertFalse(settings.isEnabled(forHost: "m.kinogo.ru"))
        XCTAssertTrue(settings.isEnabled(forHost: "kinogo.com"))
        XCTAssertTrue(settings.isEnabled(forHost: nil))
        settings.setEnabled(true, forHost: "m.kinogo.ru")
        XCTAssertTrue(settings.isEnabled(forHost: "kinogo.ru"))
    }

    /// Выключатель сайта из инкогнито живёт только в памяти: в UserDefaults и в списке
    /// настроек его нет, обычные вкладки его не видят, после конца сессии он забыт.
    func testIncognitoSiteToggleIsNotPersisted() {
        let suite = "KentikTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = BlockingSettings(defaults: defaults)
        settings.setEnabled(false, forHost: "m.kinogo.ru", incognito: true)
        XCTAssertFalse(settings.isEnabled(forHost: "kinogo.ru", incognito: true))
        XCTAssertTrue(settings.isEnabled(forHost: "kinogo.ru", incognito: false), "обычные вкладки не затронуты")
        XCTAssertTrue(settings.disabledHosts.isEmpty, "в постоянных настройках следа нет")
        XCTAssertNil(defaults.object(forKey: "shield.disabledHosts"))
        XCTAssertEqual(settings.incognitoDisabledHosts, ["kinogo.ru"])

        // Постоянно выключенный сайт можно временно включить в инкогнито.
        settings.setEnabled(false, forHost: "serial.example", incognito: false)
        settings.setEnabled(true, forHost: "serial.example", incognito: true)
        XCTAssertTrue(settings.isEnabled(forHost: "serial.example", incognito: true))
        XCTAssertFalse(settings.isEnabled(forHost: "serial.example", incognito: false))
        XCTAssertEqual(settings.disabledHosts, ["serial.example"])

        settings.resetIncognitoOverrides()
        XCTAssertTrue(settings.isEnabled(forHost: "kinogo.ru", incognito: true))
        XCTAssertFalse(settings.isEnabled(forHost: "serial.example", incognito: true))
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testSyncInstallsAndRemovesListsPerSite() async throws {
        let list = try await compileTestList()
        let settings = makeSettings()
        let blocker = ContentBlocker(settings: settings)
        blocker.setRuleListsForTesting([list])
        let controller = WKUserContentController()

        blocker.sync(controller, host: "video.example.com")
        XCTAssertEqual(blocker.installedLists(on: controller).count, 1)

        settings.setEnabled(false, forHost: "example.com")
        blocker.sync(controller, host: "www.example.com")
        XCTAssertTrue(blocker.installedLists(on: controller).isEmpty, "на выключенном сайте списков нет")

        blocker.sync(controller, host: "other.org")
        XCTAssertEqual(blocker.installedLists(on: controller).count, 1, "на другом сайте списки вернулись")

        settings.isEnabledGlobally = false
        blocker.sync(controller, host: "other.org")
        XCTAssertTrue(blocker.installedLists(on: controller).isEmpty, "общий выключатель снимает всё")

        settings.isEnabledGlobally = true
        blocker.sync(controller, host: nil)
        XCTAssertEqual(blocker.installedLists(on: controller).count, 1)
    }

    func testPopupGetsItsOwnContentController() {
        let manager = TabManager()
        let opener = manager.addTab(incognito: false)
        let popupConfiguration = opener.webView.configuration
        let popup = manager.addTab(incognito: false, select: false, opener: opener, popupConfiguration: popupConfiguration)
        XCTAssertFalse(popup.webView.configuration.userContentController
                       === opener.webView.configuration.userContentController,
                       "выключение щита в окне не должно снимать правила у открывателя")
        manager.close(popup)
        manager.close(opener)
    }

    /// Встроенные списки (их собирает CI) компилируются целиком.
    func testBundledListsCompile() async throws {
        guard FilterLists.version != "dev" else {
            throw XCTSkip("локальная сборка без списков фильтров")
        }
        let package = try XCTUnwrap(FilterLists.bundledPackage(), "в бандле нет Filters/manifest.json")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ContentBlocker.shared.prepare { continuation.resume() }
        }
        // prepare может вернуться по тайм-ауту — ждём готовности.
        for _ in 0..<600 where !ContentBlocker.shared.isReady {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        XCTAssertTrue(ContentBlocker.shared.isReady)
        XCTAssertEqual(ContentBlocker.shared.failedLists, [], "не скомпилировались списки")
        let expected = package.manifest.entries().count
        XCTAssertGreaterThanOrEqual(ContentBlocker.shared.ruleLists.count, expected)
        XCTAssertEqual(ContentBlocker.shared.activeVersion, package.manifest.version)
        let rules = package.manifest.entries().reduce(0) { $0 + ($1.rules ?? 0) }
        XCTAssertGreaterThan(rules, 50_000, "подозрительно мало правил: \(rules)")
    }

    private func compileTestList() async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "kentik-unit-test-rules",
                encodedContentRuleList: FilterLists.testRulesJSON
            ) { list, error in
                if let list { continuation.resume(returning: list) } else {
                    continuation.resume(throwing: error ?? NSError(domain: "test", code: 1))
                }
            }
        }
    }
}

/// Набор рекламных хостов из релиза «lists», свежесть списков, русские подписи.
final class ListsUpdateAndTextTests: XCTestCase {

    private func writeHosts(_ version: String, _ hosts: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: ["version": version, "hosts": hosts])
        try data.write(to: url)
        return url
    }

    func testAdHostsTakesNewerOfDownloadedAndBundled() throws {
        let bundled = try writeHosts("202611010000", ["old-ad.example"])
        let downloaded = try writeHosts("202611200300", ["fresh-ad.example"])
        defer {
            try? FileManager.default.removeItem(at: bundled)
            try? FileManager.default.removeItem(at: downloaded)
        }
        let hosts = AdHosts()
        hosts.add(["test-ad.example"])
        XCTAssertEqual(hosts.load(from: [downloaded, bundled]), "202611200300")
        XCTAssertTrue(hosts.contains(host: "x.fresh-ad.example"))
        XCTAssertFalse(hosts.contains(host: "old-ad.example"), "старый набор заменён свежим")
        XCTAssertTrue(hosts.contains(host: "popads.net"), "встроенный seed остаётся всегда")
        XCTAssertTrue(hosts.contains(host: "test-ad.example"), "тестовые хосты остаются")
        // Порядок файлов не важен: выбирается более свежий.
        XCTAssertEqual(AdHosts().load(from: [bundled, downloaded]), "202611200300")
        XCTAssertNil(AdHosts().load(from: [URL(fileURLWithPath: "/nonexistent/hosts.json")]))
    }

    func testManifestWithHostsEntry() throws {
        let sha = String(repeating: "cd", count: 32)
        let object: [String: Any] = [
            "schema": 1, "version": "202611201230",
            "lists": [["id": "ads", "variant": "s26", "file": "ads.s26.json.deflate", "sha256": sha]],
            "hosts": ["file": "ad_hosts.202611201230.json", "sha256": sha, "bytes": 10, "count": 5000,
                      "version": "202611201230"],
        ]
        let manifest = try FilterListManifest.parse(try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(manifest.hosts?.file, "ad_hosts.202611201230.json")
        XCTAssertEqual(manifest.hosts?.count, 5000)

        var bad = object
        bad["hosts"] = ["file": "../evil.json", "sha256": sha]
        XCTAssertThrowsError(try FilterListManifest.parse(try JSONSerialization.data(withJSONObject: bad)))
    }

    func testListsFreshness() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = FilterLists.date(ofVersion: "202611201200")!
        XCTAssertNil(FilterLists.date(ofVersion: "dev"))

        let fresh = FilterLists.freshness(version: "202611200300", lastCheck: now, now: now, calendar: calendar)
        XCTAssertFalse(fresh.isStale)
        XCTAssertEqual(fresh.text, "Списки от 20 ноября · проверено сегодня")

        let old = FilterLists.freshness(version: "202610300300", lastCheck: now.addingTimeInterval(-3 * 86_400),
                                        now: now, calendar: calendar)
        XCTAssertTrue(old.isStale)
        XCTAssertEqual(old.ageDays, 21)
        XCTAssertTrue(old.text.hasPrefix("Списки устарели на 21 день"), old.text)
        XCTAssertTrue(old.text.hasSuffix("проверено 3 дня назад"), old.text)

        XCTAssertEqual(FilterLists.freshness(version: "dev", lastCheck: nil, now: now, calendar: calendar).text,
                       "Списки фильтров: dev")
    }

    func testRussianPlural() {
        let forms = [0, 1, 2, 4, 5, 11, 12, 21, 22, 25, 101, 111].map { RussianPlural.form($0, "окно", "окна", "окон") }
        XCTAssertEqual(forms, ["окон", "окно", "окна", "окна", "окон", "окон", "окон", "окно", "окна", "окон", "окно", "окон"])
    }

    @MainActor
    func testShieldStatCaptions() {
        XCTAssertEqual(ShieldSheetViewController.statCaption(1, .popups), "окно заблокировано")
        XCTAssertEqual(ShieldSheetViewController.statCaption(2, .popups), "окна заблокированы")
        XCTAssertEqual(ShieldSheetViewController.statCaption(5, .popups), "окон заблокировано")
        XCTAssertEqual(ShieldSheetViewController.statCaption(1, .redirects), "переход заблокирован")
        XCTAssertEqual(ShieldSheetViewController.statCaption(3, .redirects), "перехода заблокированы")
        XCTAssertEqual(ShieldSheetViewController.statCaption(0, .hidden), "элементов скрыто")
        XCTAssertEqual(ShieldSheetViewController.statCaption(21, .hidden), "элемент скрыт")
    }
}

import XCTest
import WebKit
@testable import Kentik

/// «Face ID для инкогнито» включено по умолчанию, выбор пользователя сохраняется.
@MainActor
final class IncognitoFaceIDSettingTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let name = "kentik.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testOnByDefaultForNewAndUntouchedInstalls() {
        let settings = AppSettings(defaults: defaults())
        XCTAssertTrue(settings.incognitoFaceID, "новая установка: Face ID включено")
        XCTAssertFalse(settings.incognitoFaceIDChangedByUser)
    }

    func testUserChoiceIsKept() {
        let d = defaults()
        let settings = AppSettings(defaults: d)
        settings.incognitoFaceID = false
        XCTAssertFalse(AppSettings(defaults: d).incognitoFaceID, "выключил сам — остаётся выключенным")
        XCTAssertTrue(AppSettings(defaults: d).incognitoFaceIDChangedByUser)
        settings.incognitoFaceID = true
        XCTAssertTrue(AppSettings(defaults: d).incognitoFaceID)
    }

    func testLegacyValueFrom101CountsAsUserChoice() {
        // В 1.0.1 значение писал только переключатель: оно есть — значит, пользователь выбирал.
        let off = defaults()
        off.set(false, forKey: "settings.incognitoFaceID")
        XCTAssertFalse(AppSettings(defaults: off).incognitoFaceID)
        let on = defaults()
        on.set(true, forKey: "settings.incognitoFaceID")
        XCTAssertTrue(AppSettings(defaults: on).incognitoFaceID)
    }
}

/// Замок инкогнито: заперт при запуске, после фона и после долгого ухода на обычные вкладки;
/// пока пользователь в инкогнито — не запирается.
@MainActor
final class IncognitoLockLogicTests: XCTestCase {

    func testLockedAtLaunchWhenEnabled() {
        XCTAssertTrue(IncognitoLock(enabled: { true }).isLocked)
        XCTAssertFalse(IncognitoLock(enabled: { false }).isLocked, "нет кода-пароля или выключено — как раньше")
    }

    func testGraceAfterLeavingIncognito() {
        let lock = IncognitoLock(enabled: { true })
        lock.reset()   // как после успешного Face ID
        let t0 = Date()
        lock.noteVisible(incognito: true, now: t0)
        XCTAssertFalse(lock.isLocked)
        lock.noteVisible(incognito: false, now: t0.addingTimeInterval(1))
        XCTAssertNotNil(lock.leftAt, "ушли на обычные вкладки — пошёл отсчёт")
        // Короткий заход в обычную вкладку — без Face ID.
        lock.noteVisible(incognito: true, now: t0.addingTimeInterval(1 + IncognitoLock.grace - 1))
        XCTAssertFalse(lock.isLocked)
        XCTAssertNil(lock.leftAt)
        // Долго на обычных вкладках — вход в инкогнито снова через замок.
        lock.noteVisible(incognito: false, now: t0.addingTimeInterval(100))
        lock.noteVisible(incognito: true, now: t0.addingTimeInterval(100 + IncognitoLock.grace + 1))
        XCTAssertTrue(lock.isLocked)
    }

    func testBackgroundLocksEvenWithoutIncognitoTabs() {
        let lock = IncognitoLock(enabled: { true })
        lock.reset()
        lock.lockIfNeeded(hasIncognitoTabs: false)
        XCTAssertTrue(lock.isLocked, "следующий вход в инкогнито — тоже через Face ID")
    }

    func testDisabledNeverLocks() {
        let lock = IncognitoLock(enabled: { false })
        lock.lock()
        XCTAssertFalse(lock.isLocked)
        lock.noteVisible(incognito: false, now: Date())
        lock.noteVisible(incognito: true, now: Date().addingTimeInterval(3600))
        XCTAssertFalse(lock.isLocked)
    }
}

/// История: запись с commit, слияние с недоступным файлом, вкладки при закрытии.
@MainActor
final class HistoryAndTabsTests: XCTestCase {

    func testHistoryPersistsAndReloads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("history.json")
        let store = HistoryStore(fileURL: file, persist: true)
        store.record(url: URL(string: "https://serials.example/mentalist")!, title: "Менталист", incognito: false)
        store.record(url: URL(string: "https://secret.example/")!, title: "Тайна", incognito: true)
        store.saveNow()
        let again = HistoryStore(fileURL: file, persist: true)
        XCTAssertEqual(again.entries.map(\.title), ["Менталист"], "после перезапуска история на месте, инкогнито нет")
    }

    func testClosingNormalTabStaysInNormalMode() {
        let manager = TabManager()
        let a = manager.addTab(incognito: false)
        let secret = manager.addTab(incognito: true)
        let b = manager.addTab(incognito: false)
        manager.select(a)
        manager.close(a)
        XCTAssertTrue(manager.selectedTab === b, "закрыв обычную вкладку, не попадаем в инкогнито")
        [secret, b].forEach { manager.close($0) }
    }
}

/// Скриптлеты AdGuard: разбор набора, сайты, щит, манифест.
@MainActor
final class AdGuardScriptletsTests: XCTestCase {

    private func packageJSON(version: String = "202611221200") -> Data {
        let object: [String: Any] = [
            "schema": 1, "version": version, "library": "2.6.0", "rules": 2,
            "hosts": ["youtube.com", "m.youtube.com"],
            "scripts": [["kind": "scriptlets", "rules": 2, "source": "(function(){window.__kentikAdg=1;})();"]],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testParseAndHosts() throws {
        let package = try XCTUnwrap(AdGuardScriptlets.parse(packageJSON()))
        XCTAssertEqual(package.version, "202611221200")
        let adg = AdGuardScriptlets()
        adg.apply(package)
        XCTAssertTrue(adg.applies(to: "m.youtube.com"))
        XCTAssertTrue(adg.applies(to: "www.youtube.com"))
        XCTAssertFalse(adg.applies(to: "kinogo.online"))
        XCTAssertFalse(adg.applies(to: "notyoutube.com"))
        XCTAssertNil(AdGuardScriptlets.parse(Data("{}".utf8)))
        XCTAssertNil(AdGuardScriptlets.parse(packageJSON(version: "latest")))
    }

    func testInstalledOnlyOnYouTubeWithShieldOn() throws {
        let adg = AdGuardScriptlets()
        adg.apply(AdGuardScriptlets.parse(packageJSON()))
        var shieldOn = true
        adg.isShieldEnabled = { _, _ in shieldOn }
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: "/*other*/", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        adg.sync(controller, host: "m.youtube.com", incognito: false)
        XCTAssertTrue(adg.isInstalled(on: controller))
        XCTAssertEqual(controller.userScripts.count, 2, "чужие скрипты остаются")
        adg.sync(controller, host: "kinogo.online", incognito: false)
        XCTAssertFalse(adg.isInstalled(on: controller), "на других сайтах скриптлетов YouTube нет")
        shieldOn = false
        adg.sync(controller, host: "www.youtube.com", incognito: false)
        XCTAssertFalse(adg.isInstalled(on: controller), "щит выключен на сайте — скриптлетов нет")
        XCTAssertEqual(controller.userScripts.count, 1)
    }

    func testBundledPackageIfPresent() throws {
        // Встроенный набор собирает CI (build_adguard.py); локально без CI его может не быть.
        guard let url = AdGuardScriptlets.bundledURL else { throw XCTSkip("встроенного adguard.json нет") }
        let package = try XCTUnwrap(AdGuardScriptlets.parse(try Data(contentsOf: url)), "adguard.json не разобрался")
        XCTAssertGreaterThan(package.rules, 5)
        XCTAssertTrue(package.hosts.contains("youtube.com") || package.hosts.contains("m.youtube.com"))
        let all = package.sources.joined()
        XCTAssertTrue(all.contains("adPlacements"), "нет правил против adPlacements")
        XCTAssertTrue(all.contains("google_ad_status"), "нет set-constant google_ad_status")
    }

    func testManifestAdGuardEntry() throws {
        func manifest(_ adguard: String) -> Data {
            Data("""
            {"schema":1,"version":"202611221200","lists":[{"id":"ads","variant":"s26","file":"ads.s26.json.deflate",
             "sha256":"\(String(repeating: "a", count: 64))"}]\(adguard)}
            """.utf8)
        }
        let ok = try FilterListManifest.parse(manifest(",\"adguard\":{\"file\":\"adguard.202611221200.json\",\"sha256\":\"\(String(repeating: "b", count: 64))\",\"version\":\"202611221200\"}"))
        XCTAssertEqual(ok.adguard?.version, "202611221200")
        XCTAssertNil(try FilterListManifest.parse(manifest("")).adguard)
        XCTAssertThrowsError(try FilterListManifest.parse(manifest(",\"adguard\":{\"file\":\"../x.json\",\"sha256\":\"\(String(repeating: "b", count: 64))\",\"version\":\"1\"}")))
    }
}

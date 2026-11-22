import XCTest
import WebKit
@testable import Kentik

/// 1.0.3: скриптлеты AdGuard для фреймов (плееры сериалов в чужих iframe).
@MainActor
final class FrameScriptletsTests: XCTestCase {

    private func packageJSON(frames: Bool) -> Data {
        var object: [String: Any] = [
            "schema": 1, "version": "202611231200", "library": "2.6.0", "rules": 2,
            "hosts": ["youtube.com", "m.youtube.com"],
            "scripts": [["kind": "scriptlets", "rules": 2, "source": "(function(){window.__kentikAdg=1;})();"]],
        ]
        if frames {
            object["frameScripts"] = [["kind": "scriptlets", "rules": 3, "source": "(function(){window.__kentikFrames=1;})();"]]
            object["frameHosts"] = ["kodik.info", "Lumex.Space"]
            object["frameRules"] = 3
        }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testParseFrameScripts() throws {
        let package = try XCTUnwrap(AdGuardScriptlets.parse(packageJSON(frames: true)))
        XCTAssertEqual(package.frameSources.count, 1)
        XCTAssertEqual(package.frameRules, 3)
        XCTAssertEqual(package.frameHosts, ["kodik.info", "lumex.space"])
        // Набор 1.0.2 (без frameScripts) по-прежнему разбирается.
        let old = try XCTUnwrap(AdGuardScriptlets.parse(packageJSON(frames: false)))
        XCTAssertTrue(old.frameSources.isEmpty)
    }

    /// Скрипты для фреймов стоят на любом сайте со щитом (плеер — в чужом iframe), скрипты
    /// YouTube — только на YouTube; щит выключен на сайте — ничего.
    func testFrameScriptsOnEverySiteWithShield() throws {
        let adg = AdGuardScriptlets()
        adg.apply(AdGuardScriptlets.parse(packageJSON(frames: true)))
        var shieldOn = true
        adg.isShieldEnabled = { _, _ in shieldOn }
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: "/*other*/", injectionTime: .atDocumentStart, forMainFrameOnly: true))

        adg.sync(controller, host: "kinogo.online", incognito: false)
        XCTAssertTrue(adg.areFrameScriptsInstalled(on: controller), "на сайте с сериалами скрипты для фреймов стоят")
        XCTAssertFalse(adg.isInstalled(on: controller), "скриптов YouTube там нет")
        let frameScript = try XCTUnwrap(controller.userScripts.first { $0.source.hasPrefix(AdGuardScriptlets.frameMarker) })
        XCTAssertFalse(frameScript.isForMainFrameOnly, "во все фреймы")
        XCTAssertEqual(frameScript.injectionTime, .atDocumentStart)

        adg.sync(controller, host: "m.youtube.com", incognito: false)
        XCTAssertTrue(adg.areFrameScriptsInstalled(on: controller))
        XCTAssertTrue(adg.isInstalled(on: controller))
        XCTAssertEqual(controller.userScripts.count, 3, "чужой скрипт + фреймы + YouTube, без повторов")

        shieldOn = false
        adg.sync(controller, host: "kinogo.online", incognito: false)
        XCTAssertFalse(adg.areFrameScriptsInstalled(on: controller), "щит выключен на сайте — скриптлетов нет")
        XCTAssertFalse(adg.isInstalled(on: controller))
        XCTAssertEqual(controller.userScripts.count, 1, "чужие скрипты остаются")
    }

    func testBundledFrameScriptsIfPresent() throws {
        guard let url = AdGuardScriptlets.bundledURL else { throw XCTSkip("встроенного adguard.json нет") }
        let package = try XCTUnwrap(AdGuardScriptlets.parse(try Data(contentsOf: url)))
        guard !package.frameSources.isEmpty else { throw XCTSkip("в наборе нет скриптлетов для фреймов (источники не скачались)") }
        XCTAssertTrue(package.frameHosts.contains("kentik-player.test"), "нет своих правил Kentik")
        XCTAssertGreaterThan(package.frameRules, 100, "правил для фреймов подозрительно мало")
        let all = package.frameSources.joined()
        XCTAssertTrue(all.contains("kodik"), "нет правил для плеера Kodik")
    }
}

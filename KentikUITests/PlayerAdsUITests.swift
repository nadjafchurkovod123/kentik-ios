import XCTest

/// Реклама внутри плееров сериалов (1.0.3) на фикстуре tests/fixtures/vast с НАСТОЯЩИМИ
/// списками фильтров: сайт kinogo.online, плеер cinemar.cc в чужом iframe тянет VAST с хостов
/// AdAngle / distribrey / adstag и ролик с cdn.mbt-8.com (адреса — как на настоящем
/// kinogo.online), плеер kentik-player.test — правило `$domain=` для фрейма и скриптлет
/// json-prune для конфига плеера. Имена указывают на сервер фикстур через /etc/hosts
/// (шаг CI «Имена для фикстуры плееров»); контрольный хост vast-control.kentik.test ни в одном
/// списке не значится — если он не загрузился, имена не настроены и проверка недостоверна.
final class PlayerAdsUITests: XCTestCase {

    static let top = "http://kinogo.online:8765/vast/top.html"

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    /// Итог фикстуры из заголовка «VAST готово a=B c=OK …».
    @MainActor
    private func run(_ arguments: [String], name: String) -> [String: String] {
        let app = kLaunch(arguments, start: Self.top)
        let title = app.staticTexts["pageTitle"]
        _ = title.waitForExistence(timeout: 300)
        let done = NSPredicate(format: "label BEGINSWITH %@", "VAST готово")
        let finished = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: done, object: title)], timeout: 300) == .completed
        sleep(2)
        kShot(app, "\(name)-player")
        let label = title.label
        XCTContext.runActivity(named: "\(name): \(label)") { _ in }
        app.terminate()
        XCTAssertTrue(finished, "\(name): фикстура не досчитала («\(label)»)")
        var result: [String: String] = [:]
        for part in label.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { result[String(kv[0])] = String(kv[1]) }
        }
        return result
    }

    /// Без блокировщика и скриптлетов реклама проходит (фикстура настоящая), со щитом — нет,
    /// а серия играет.
    @MainActor
    func testInPlayerAdsBlockedAndEpisodePlays() throws {
        let off = run(["-KentikNoBlocker", "-KentikNoAdGuard"], name: "vast-OFF")
        guard off["c"] == "OK", off["kc"] == "OK" else {
            throw XCTSkip("контрольный хост не загрузился (c=\(off["c"] ?? "-"), kc=\(off["kc"] ?? "-")) — /etc/hosts не настроен")
        }
        for key in ["a", "d", "s", "m", "k"] {
            XCTAssertEqual(off[key], "OK", "без щита запрос \(key) должен проходить: \(off)")
        }
        XCTAssertEqual(off["p"], "K", "без скриптлетов рекламные поля конфига остаются: \(off)")

        let on = run([], name: "vast-ON")
        XCTAssertEqual(on["c"], "OK", "контроль со щитом: \(on)")
        XCTAssertEqual(on["kc"], "OK", "контроль во фрейме со щитом: \(on)")
        XCTAssertEqual(on["a"], "B", "VAST AdAngle (agl008.shop) из фрейма плеера не заблокирован: \(on)")
        XCTAssertEqual(on["d"], "B", "VAST distribrey.com не заблокирован: \(on)")
        XCTAssertEqual(on["s"], "B", "VAST adstag0102.xyz не заблокирован: \(on)")
        XCTAssertEqual(on["m"], "B", "рекламный ролик cdn.mbt-8.com не заблокирован: \(on)")
        XCTAssertEqual(on["v"], "OK", "серия не играет: \(on)")
        XCTAssertEqual(on["p"], "P", "скриптлет для фрейма не вырезал рекламные поля конфига: \(on)")
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
            XCTAssertEqual(on["k"], "B", "правило `$domain=` плеера не сработало внутри его фрейма (if-frame-url): \(on)")
        }
    }
}

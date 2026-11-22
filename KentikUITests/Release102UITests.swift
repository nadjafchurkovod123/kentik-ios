import XCTest

/// Проверки 1.0.2 на фикстурах: история (запись, показ, перезапуск, инкогнито не пишет),
/// фиолетовое инкогнито, Face ID по умолчанию и на каждом входе в инкогнито, видео из
/// инкогнито закрывается замком, плеер во фрейме на весь экран продолжает рисовать.
final class Release102UITests: XCTestCase {

    static let host = "127.0.0.1:8765"
    static var fixtures: String { "http://\(host)" }

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    // MARK: - История

    /// Обычные страницы (и переход pushState) пишутся с заголовками, инкогнито — нет;
    /// «История» видна на новой вкладке и в переключателе вкладок.
    @MainActor
    func testHistoryRecordedShownAndIncognitoNotRecorded() {
        let app = kLaunch(["-KentikIncognitoFaceIDOff"], start: "\(Self.fixtures)/hello.html")
        kWaitTitle(app, "Kentik Hello", timeout: 300)

        kTypeAddress(app, "\(Self.host)/spa.html")
        kWaitTitle(app, "Kentik SPA")
        let next = app.webViews.buttons["Дальше"]
        XCTAssertTrue(next.waitForExistence(timeout: 20), "нет кнопки «Дальше»")
        next.tap()
        kWaitTitle(app, "Kentik SPA · 2")

        // Инкогнито историю не пишет.
        kMenu(app, "Новая вкладка инкогнито")
        kTypeAddress(app, "\(Self.host)/secret.html")
        kWaitTitle(app, "Kentik Secret", contains: true)

        // Обратно в обычные вкладки, новая вкладка — домашний экран с «Историей».
        let segment = kShowTabs(app, incognito: false)
        _ = segment
        app.buttons["newTabInSwitcher"].tap()
        let cancel = app.buttons["cancelEditing"]
        if cancel.waitForExistence(timeout: 5) { cancel.tap() }
        let homeHistory = app.buttons["homeHistory"]
        XCTAssertTrue(homeHistory.waitForExistence(timeout: 10), "на новой вкладке нет кнопки «История»")
        kShot(app, "h102-01-home-history-button")
        homeHistory.tap()

        XCTAssertTrue(app.descendants(matching: .any)["historyView"].waitForExistence(timeout: 10), "история не открылась")
        let rows = app.descendants(matching: .any).matching(identifier: "historyRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "история пуста")
        let labels = rows.allElementsBoundByIndex.map(\.label)
        kShot(app, "h102-02-history-list")
        XCTAssertTrue(labels.contains { $0.contains("Kentik Hello") }, "нет «Kentik Hello» в истории: \(labels)")
        XCTAssertTrue(labels.contains { $0.contains("Kentik SPA · 2") }, "нет перехода pushState в истории: \(labels)")
        XCTAssertFalse(labels.contains { $0.contains("Secret") || $0.contains("secret") }, "инкогнито попало в историю: \(labels)")
        app.buttons["historyDone"].tap()

        // «История» в переключателе вкладок.
        _ = kShowTabs(app, incognito: false)
        let switcherHistory = app.buttons["historyInSwitcher"]
        XCTAssertTrue(switcherHistory.waitForExistence(timeout: 5), "в переключателе нет кнопки «История»")
        kShot(app, "h102-03-switcher-history-button")
        switcherHistory.tap()
        XCTAssertTrue(app.descendants(matching: .any)["historyView"].waitForExistence(timeout: 10),
                      "история из переключателя не открылась")
        kShot(app, "h102-04-history-from-switcher")
    }

    /// История на диске: после перезапуска приложения она на месте.
    @MainActor
    func testHistorySurvivesRestart() {
        var app = kLaunch(["-KentikPersistSession", "-KentikFreshHistory", "-KentikIncognitoFaceIDOff"],
                          start: "\(Self.fixtures)/hello.html")
        kWaitTitle(app, "Kentik Hello", timeout: 300)
        kTypeAddress(app, "\(Self.host)/links.html")
        kWaitTitle(app, "Kentik Links")
        sleep(2)
        XCUIDevice.shared.press(.home)   // уход в фон сохраняет историю
        sleep(3)
        app.terminate()

        app = kLaunch(["-KentikPersistSession", "-KentikIncognitoFaceIDOff"], start: nil)
        _ = app.textFields["addressBar"].waitForExistence(timeout: 120)
        kMenu(app, "История")
        let rows = app.descendants(matching: .any).matching(identifier: "historyRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "после перезапуска история пуста")
        let labels = rows.allElementsBoundByIndex.map(\.label)
        kShot(app, "h102-05-history-after-restart")
        XCTAssertTrue(labels.contains { $0.contains("Kentik Hello") } && labels.contains { $0.contains("Kentik Links") },
                      "после перезапуска в истории: \(labels)")
    }

    // MARK: - Фиолетовое инкогнито

    @MainActor
    func testIncognitoIsPurple() {
        let app = kLaunch(["-KentikIncognitoFaceIDOff"], start: "\(Self.fixtures)/hello.html")
        kWaitTitle(app, "Kentik Hello", timeout: 300)
        let normalShot = kShot(app, "p102-01-normal")
        let toolbar = app.buttons["menuButton"].frame
        let normalBar = kAverageColor(normalShot, in: toolbar.insetBy(dx: -30, dy: 2))
        XCTAssertFalse(kIsPurple(normalBar), "обычная панель стала фиолетовой: \(normalBar)")

        kMenu(app, "Новая вкладка инкогнито")
        let cancel = app.buttons["cancelEditing"]
        if cancel.waitForExistence(timeout: 5) { cancel.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["incognitoHome"].waitForExistence(timeout: 10), "нет карточки инкогнито")
        XCTAssertTrue(app.descendants(matching: .any)["incognitoBadge"].waitForExistence(timeout: 5),
                      "нет значка «Инкогнито» в адресной строке")
        sleep(1)
        let home = kShot(app, "p102-02-incognito-home")
        let bar = kAverageColor(home, in: app.buttons["menuButton"].frame.insetBy(dx: -30, dy: 2))
        XCTAssertTrue(kIsPurple(bar), "панель инкогнито не фиолетовая: \(bar)")
        let page = kAverageColor(home, in: app.descendants(matching: .any)["homeView"].frame.insetBy(dx: 20, dy: 40))
        XCTAssertTrue(kIsPurple(page), "новая вкладка инкогнито не фиолетовая: \(page)")

        kTypeAddress(app, "\(Self.host)/secret.html")
        kWaitTitle(app, "Kentik Secret", contains: true)
        let pageShot = kShot(app, "p102-03-incognito-page")
        XCTAssertTrue(kIsPurple(kAverageColor(pageShot, in: app.buttons["backButton"].frame.insetBy(dx: -20, dy: 2))),
                      "панель под страницей инкогнито не фиолетовая")
        XCTAssertTrue(app.descendants(matching: .any)["incognitoBadge"].exists, "нет значка «Инкогнито» на странице")

        let segment = kShowTabs(app, incognito: true)
        _ = segment
        let close = app.buttons["closeTab"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "нет карточки инкогнито")
        sleep(1)
        let switcher = kShot(app, "p102-04-incognito-switcher")
        let header = CGRect(x: close.frame.minX - 50, y: close.frame.minY + 2, width: 46, height: 5)
        XCTAssertTrue(kIsPurple(kAverageColor(switcher, in: header)), "шапка карточки инкогнито не фиолетовая")
        let seg = app.segmentedControls["tabSwitcherSegment"].frame
        let segEdge = CGRect(x: seg.minX + 3, y: seg.midY - 3, width: 8, height: 6)
        XCTAssertTrue(kIsPurple(kAverageColor(switcher, in: segEdge)), "переключатель разделов не фиолетовый")
        let gap = CGRect(x: switcher.size.width / 2 - 3, y: switcher.size.height * 0.3, width: 6, height: 24)
        XCTAssertTrue(kIsPurple(kAverageColor(switcher, in: gap)), "фон раздела «Инкогнито» не фиолетовый")
        app.segmentedControls["tabSwitcherSegment"].buttons.element(boundBy: 0).tap()
        sleep(1)
        let normal = kShot(app, "p102-05-normal-switcher")
        XCTAssertFalse(kIsPurple(kAverageColor(normal, in: gap)), "обычный раздел стал фиолетовым")
    }

    // MARK: - Face ID

    /// Face ID включено по умолчанию: «Новая вкладка инкогнито» спрашивает; пока пользователь
    /// в инкогнито — не спрашивает снова; короткий заход в обычную вкладку — тоже.
    @MainActor
    func testFaceIDDefaultOnAndNewIncognitoTabAsks() {
        let app = kLaunch(["-KentikFakeAuth"], start: "\(Self.fixtures)/hello.html")
        kWaitTitle(app, "Kentik Hello", timeout: 300)

        // Настройка включена по умолчанию.
        kMenu(app, "Настройки")
        let toggle = app.switches["faceIDToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "нет переключателя Face ID")
        XCTAssertEqual(toggle.value as? String, "1", "Face ID для инкогнито по умолчанию выключено")
        kShot(app, "f102-00-settings-faceid-on")
        app.buttons["settingsDone"].tap()
        sleep(1)

        kMenu(app, "Новая вкладка инкогнито")
        kAnswerFaceID(app, allow: false, "новая вкладка инкогнито (отмена)")
        sleep(1)
        XCTAssertEqual(app.buttons["tabsButton"].value as? String, "1", "после отмены открылась вкладка инкогнито")

        kMenu(app, "Новая вкладка инкогнито")
        kShot(app, "f102-01-new-incognito-asks")
        kAnswerFaceID(app, allow: true, "новая вкладка инкогнито")
        XCTAssertTrue(app.descendants(matching: .any)["incognitoBadge"].waitForExistence(timeout: 10), "инкогнито не открылось")
        kTypeAddress(app, "\(Self.host)/locked.html?n=1")
        kWaitTitle(app, "Секрет-1")

        // В инкогнито «+» больше не спрашивает.
        app.buttons["newTabButton"].tap()
        XCTAssertFalse(kFakeAuth(app).waitForExistence(timeout: 2), "Face ID спросили, хотя пользователь в инкогнито")
        let cancel = app.buttons["cancelEditing"]
        if cancel.waitForExistence(timeout: 5) { cancel.tap() }

        // Короткий заход в обычную вкладку и обратно — без Face ID.
        _ = kShowTabs(app, incognito: false)
        app.staticTexts["Kentik Hello"].firstMatch.tap()
        kWaitTitle(app, "Kentik Hello")
        let segment = kShowTabs(app, incognito: true)
        XCTAssertFalse(kFakeAuth(app).waitForExistence(timeout: 2), "Face ID спросили через пару секунд после ухода")
        XCTAssertTrue(app.staticTexts["Секрет-1"].waitForExistence(timeout: 5), "карточки инкогнито не видны")
        _ = segment
        kShot(app, "f102-02-incognito-again-no-face-id")
    }

    /// «Открыть в инкогнито» из меню ссылки сначала спрашивает Face ID.
    @MainActor
    func testOpenLinkInIncognitoAsksFaceID() {
        let app = kLaunch(["-KentikFakeAuth"], start: "\(Self.fixtures)/links.html")
        kWaitTitle(app, "Kentik Links", timeout: 300)
        let link = app.webViews.links["Открыть Hello"]
        XCTAssertTrue(link.waitForExistence(timeout: 30), "нет ссылки")
        link.press(forDuration: 1.5)
        let item = app.buttons["Открыть в инкогнито"]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "нет пункта «Открыть в инкогнито»")
        item.tap()
        kShot(app, "f102-03-link-incognito-asks")
        kAnswerFaceID(app, allow: true, "«Открыть в инкогнито»")
        kWaitTitle(app, "Kentik Hello")
        XCTAssertTrue(app.descendants(matching: .any)["incognitoBadge"].exists, "ссылка открылась не в инкогнито")
    }

    /// Раздел «Инкогнито» в переключателе после долгого ухода на обычные вкладки (здесь —
    /// 2 с вместо 30) снова заперт и сразу спрашивает Face ID; отмена — замок, карточек нет.
    @MainActor
    func testSwitcherIncognitoSectionAsksAfterGrace() {
        let app = kLaunch(["-KentikFakeAuth", "-KentikIncognitoGrace", "2"], start: "\(Self.fixtures)/hello.html")
        kWaitTitle(app, "Kentik Hello", timeout: 300)
        kMenu(app, "Новая вкладка инкогнито")
        kAnswerFaceID(app, allow: true, "первый вход")
        kTypeAddress(app, "\(Self.host)/locked.html?n=7")
        kWaitTitle(app, "Секрет-7")

        _ = kShowTabs(app, incognito: false)
        app.staticTexts["Kentik Hello"].firstMatch.tap()
        kWaitTitle(app, "Kentik Hello")
        sleep(4)

        app.buttons["tabsButton"].tap()
        let segment = app.segmentedControls["tabSwitcherSegment"]
        XCTAssertTrue(segment.waitForExistence(timeout: 10))
        segment.buttons.element(boundBy: 1).tap()
        kShot(app, "f102-04-switcher-asks")
        kAnswerFaceID(app, allow: false, "раздел «Инкогнито» после ухода")
        XCTAssertTrue(app.buttons["unlockIncognito"].waitForExistence(timeout: 5), "нет замка в разделе «Инкогнито»")
        XCTAssertFalse(app.staticTexts["Секрет-7"].exists, "карточка инкогнито видна под замком")
        app.buttons["unlockIncognito"].tap()
        kAnswerFaceID(app, allow: true, "«Разблокировать»")
        XCTAssertTrue(app.staticTexts["Секрет-7"].waitForExistence(timeout: 5), "после Face ID карточки не видны")
        kShot(app, "f102-05-switcher-unlocked")
    }

    // MARK: - Видео из инкогнито под замком

    /// Видео из вкладки инкогнито на весь экран (системный плеер, полноэкранный элемент) и в
    /// «картинке в картинке»: замок при уходе в фон закрывает всё и ставит на паузу.
    @MainActor
    func testIncognitoMediaClosedOnLock() {
        for (button, check) in [("Системный", "native"), ("На весь экран", "element"), ("PiP", "pip")] {
            let diag = Diag("media-lock-\(check)")
            let app = kLaunch(["-KentikFakeAuth"], start: "\(Self.fixtures)/hello.html", diag: diag)
            kWaitTitle(app, "Kentik Hello", timeout: 300)
            kMenu(app, "Новая вкладка инкогнито")
            kAnswerFaceID(app, allow: true, "вход в инкогнито")
            kTypeAddress(app, "\(Self.host)/media/video.html")
            kWaitTitle(app, "Kentik Video", contains: true)
            let control = app.webViews.buttons[button]
            XCTAssertTrue(control.waitForExistence(timeout: 20), "нет кнопки «\(button)»")
            control.tap()
            sleep(4)
            kShot(app, "m102-\(check)-1-presented")
            diag.snapshotState("1-presented")
            let presented = mediaPresented(diag, check)
            XCTContext.runActivity(named: "\(check): до замка показ \(presented)") { _ in }
            XCTAssertTrue(presented, "\(check): видео не ушло на весь экран / в PiP (фикстура)")

            XCUIDevice.shared.press(.home)
            sleep(3)
            kShot(app, "m102-\(check)-2-home-screen")
            app.activate()
            _ = app.wait(for: .runningForeground, timeout: 10)
            kAnswerFaceID(app, allow: false, "возвращение после видео")
            sleep(2)
            kShot(app, "m102-\(check)-3-locked")
            diag.snapshotState("3-locked")
            XCTAssertTrue(app.buttons["unlockIncognito"].waitForExistence(timeout: 5) && app.buttons["unlockIncognito"].isHittable,
                          "\(check): замок закрыт видео")
            XCTAssertFalse(mediaPresented(diag, check), "\(check): видео осталось на весь экран / в PiP под замком")
            XCTAssertFalse(diag.isVideoPlaying(), "\(check): видео играет под замком")
            app.terminate()
        }
    }

    /// Показывает ли видео (из состояния DiagProbe) нужный режим.
    @MainActor
    private func mediaPresented(_ diag: Diag, _ check: String) -> Bool {
        _ = diag.send(["op": "state"])
        let state = diag.state()
        let vids = diag.videos()
        switch check {
        case "native": return vids.contains { ($0["fsNative"] as? Bool) == true }
        case "element": return (state["fullscreen"] as? String) == "in" || (state["fullscreen"] as? String) == "entering"
        default: return vids.contains { ($0["mode"] as? String) == "picture-in-picture" }
        }
    }

    // MARK: - Плеер во фрейме на весь экран

    /// Сайт с сериалами в миниатюре: плеер с другого сайта во фрейме (HLS). «На весь экран»
    /// кнопкой самого плеера — картинка видна и меняется (видео и счётчик кадров), после
    /// выхода страница на месте.
    @MainActor
    func testIframePlayerFullscreenKeepsRendering() {
        for src in ["hls", "mp4"] {
            let diag = Diag("iframe-fullscreen-\(src)")
            let app = kLaunch([], start: "\(Self.fixtures)/media/host.html?src=\(src)", diag: diag)
            kWaitTitle(app, "Kentik Series", contains: true, timeout: 300)
            let play = app.webViews.buttons["Пуск"]
            XCTAssertTrue(play.waitForExistence(timeout: 20), "нет кнопки «Пуск» в плеере")
            play.tap()
            XCTAssertTrue(kWaitTitle(app, "идёт", contains: true, timeout: 30), "\(src): видео во фрейме не пошло")
            sleep(2)
            kShot(app, "v102-\(src)-1-inline")

            // Дважды: в 1.0.1 после первого выхода веб-вью схлопывалась, и второй раз было нечего показывать.
            for round in 1...2 {
                let fsButton = app.webViews.buttons["На весь экран"]
                XCTAssertTrue(fsButton.waitForExistence(timeout: 10) && fsButton.isHittable,
                              "\(src) \(round): кнопки «На весь экран» не видно (страница пустая?)")
                if fsButton.exists { fsButton.tap() }
                sleep(4)
                let a = kShot(app, "v102-\(src)-\(round)-fullscreen-a")
                sleep(2)
                let b = kShot(app, "v102-\(src)-\(round)-fullscreen-b")
                diag.snapshotState("\(round)-fullscreen")
                let state = diag.state()
                let stats = Pixels.stats(a)
                let diff = Pixels.difference(a, b)
                XCTContext.runActivity(named: "\(src) \(round): весь экран \(state["fullscreen"] ?? "?"), светлых \(stats.lit), цветных \(stats.colorful), разница \(diff)") { _ in }
                XCTAssertEqual(state["fullscreen"] as? String, "in", "\(src) \(round): WebKit не в полноэкранном режиме")
                XCTAssertGreaterThan(stats.colorful, 0.03, "\(src) \(round): на весь экран чёрный экран (нет картинки видео)")
                XCTAssertGreaterThan(diff, 1.0, "\(src) \(round): картинка на весь экран не меняется")

                diag.eval("(document.exitFullscreen||document.webkitExitFullscreen).call(document); 'ok'", frames: "url:player.html")
                sleep(3)
                let after = kShot(app, "v102-\(src)-\(round)-after-fullscreen")
                diag.snapshotState("\(round)-after")
                XCTAssertTrue(app.staticTexts["pageTitle"].waitForExistence(timeout: 5), "после выхода нет адресной строки")
                let frame = (diag.state()["webViewFrame"] as? [Int]) ?? [0, 0, 0, 0]
                XCTAssertGreaterThan(frame.count == 4 ? frame[2] * frame[3] : 0, 10_000, "\(src) \(round): после выхода веб-вью без размера: \(frame)")
                XCTAssertGreaterThan(Pixels.stats(after).lit, 0.05, "\(src) \(round): после выхода страница пустая")
            }
            app.terminate()
        }
    }
}

import XCTest

/// Замок инкогнито (настройка «Face ID для инкогнито»). Пока вкладки инкогнито заперты,
/// ни переключатель вкладок, ни браузер не показывают из них ничего: ни заголовков, ни снимков,
/// ни текста страниц — в том числе в дереве доступности (его читает VoiceOver, и его же видит
/// XCUITest). Face ID заменён тестовым запросом «Разрешить / Отменить» (-KentikFakeAuth):
/// в симуляторе нет ни Face ID, ни кода-пароля, и настоящая проверка проходит сама.
/// Фикстура — tests/fixtures/locked.html?n=N: заголовок «Секрет-N», на странице «Тайна номер N».
final class IncognitoLockUITests: XCTestCase {

    static let host = "127.0.0.1:8765"
    static let fixtures = "http://\(host)"

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    // MARK: - Переключатель вкладок

    /// На экране обычная вкладка, приложение ушло в фон и вернулось (Face ID не спрашивают —
    /// инкогнито не на экране). Раздел «Инкогнито» в переключателе показывает только замок;
    /// «+» там сначала спрашивает Face ID; после разблокировки карточки снова видны.
    @MainActor
    func testSwitcherHidesIncognitoAfterBackground() {
        let app = launchWithTwoSecrets()

        // Возвращаемся на обычную вкладку.
        let segment = showTabs(app, incognito: false)
        app.buttons["doneTabs"].tap()
        waitForTitle(app, "Kentik Hello")

        sendToBackgroundAndBack(app)
        XCTAssertFalse(fakeAuthAlert(app).waitForExistence(timeout: 2),
                       "Face ID спросили, хотя на экране обычная вкладка")
        attachScreenshot(app, name: "lock-01-normal-tab-after-background")

        app.buttons["tabsButton"].tap()
        XCTAssertTrue(segment.waitForExistence(timeout: 10), "нет переключателя вкладок")
        segment.buttons.element(boundBy: 1).tap()
        // Сразу, ещё во время перехода между разделами.
        attachScreenshot(app, name: "lock-02-incognito-segment-at-once")
        assertIncognitoHidden(app, "«Инкогнито» сразу после переключения")
        sleep(1)
        attachScreenshot(app, name: "lock-03-incognito-segment-locked")
        assertSwitcherLocked(app, "«Инкогнито» после возвращения из фона")

        // Туда и обратно.
        segment.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Kentik Hello"].waitForExistence(timeout: 5), "обычные вкладки не видны")
        segment.buttons.element(boundBy: 1).tap()
        assertSwitcherLocked(app, "«Вкладки» → «Инкогнито»")
        segment.buttons.element(boundBy: 0).tap()
        segment.buttons.element(boundBy: 1).tap()
        assertSwitcherLocked(app, "второй раз «Вкладки» → «Инкогнито»")

        // «+» в запертом инкогнито сначала спрашивает Face ID; отмена — ничего не открывается.
        app.buttons["newTabInSwitcher"].tap()
        let alert = fakeAuthAlert(app)
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "«+» в запертом инкогнито не спросил Face ID")
        assertIncognitoHidden(app, "под запросом Face ID от «+»")
        attachScreenshot(app, name: "lock-04-plus-asks-face-id")
        if alert.exists { alert.buttons["Отменить"].tap() }
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "переключатель закрылся")
        if segment.exists {
            XCTAssertTrue(segment.buttons.element(boundBy: 1).label.contains("2"),
                          "после отмены «+» вкладок инкогнито: \(segment.buttons.element(boundBy: 1).label)")
        }
        assertSwitcherLocked(app, "после отмены Face ID")

        // Разблокировка возвращает карточки.
        unlock(app)
        XCTAssertTrue(app.staticTexts["Секрет-1"].waitForExistence(timeout: 5), "после разблокировки нет «Секрет-1»")
        XCTAssertTrue(app.staticTexts["Секрет-2"].exists, "после разблокировки нет «Секрет-2»")
        sleep(1)
        attachScreenshot(app, name: "lock-05-unlocked-cards")
    }

    /// Переключатель открыт на «Инкогнито», когда приложение уходит в фон. По возвращении
    /// спрашивают Face ID, и ни под запросом, ни после отмены ничего из инкогнито не видно;
    /// переключатель (открытый сразу на «Инкогнито») показывает замок.
    @MainActor
    func testSwitcherOpenOnIncognitoWhenBackgrounding() {
        let app = launchWithTwoSecrets()

        app.buttons["tabsButton"].tap()
        let segment = app.segmentedControls["tabSwitcherSegment"]
        XCTAssertTrue(segment.waitForExistence(timeout: 10), "нет переключателя вкладок")
        XCTAssertTrue(app.staticTexts["Секрет-1"].waitForExistence(timeout: 5), "до замка карточек инкогнито не видно")
        sleep(1)
        attachScreenshot(app, name: "lock-10-switcher-before-background")

        sendToBackgroundAndBack(app)
        let alert = fakeAuthAlert(app)
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "после возвращения Face ID не спросили")
        assertIncognitoHidden(app, "под запросом Face ID после возвращения")
        attachScreenshot(app, name: "lock-11-face-id-after-background")
        if alert.exists { alert.buttons["Отменить"].tap() }
        sleep(1)
        attachScreenshot(app, name: "lock-12-face-id-cancelled")
        assertIncognitoHidden(app, "после отмены Face ID")

        if !segment.exists {
            app.buttons["tabsButton"].tap()
            XCTAssertTrue(segment.waitForExistence(timeout: 10), "нет переключателя вкладок")
        }
        assertSwitcherLocked(app, "переключатель на «Инкогнито»")
        attachScreenshot(app, name: "lock-13-switcher-locked")

        segment.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Kentik Hello"].waitForExistence(timeout: 5), "обычные вкладки не видны")
        segment.buttons.element(boundBy: 1).tap()
        assertSwitcherLocked(app, "«Вкладки» → «Инкогнито»")

        unlock(app)
        XCTAssertTrue(app.staticTexts["Секрет-1"].waitForExistence(timeout: 5), "после разблокировки нет «Секрет-1»")
        XCTAssertTrue(app.staticTexts["Секрет-2"].exists, "после разблокировки нет «Секрет-2»")
        sleep(1)
        attachScreenshot(app, name: "lock-14-switcher-unlocked")
    }

    // MARK: - Браузер

    /// На экране вкладка инкогнито. После фона браузер прячет страницу целиком: ни заголовка,
    /// ни адреса, ни текста страницы (и для VoiceOver тоже), пока Face ID не пройден.
    @MainActor
    func testBrowserHidesLockedIncognitoTab() {
        let app = launchWithTwoSecrets()
        XCTAssertTrue(app.webViews.staticTexts["Тайна номер 2"].waitForExistence(timeout: 30), "страница не отрисовалась")

        sendToBackgroundAndBack(app)
        let alert = fakeAuthAlert(app)
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "после возвращения Face ID не спросили")
        assertIncognitoHidden(app, "браузер под запросом Face ID")
        attachScreenshot(app, name: "lock-20-browser-face-id")
        if alert.exists { alert.buttons["Отменить"].tap() }

        let unlockButton = app.buttons["unlockIncognito"]
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 5), "в браузере нет замка")
        XCTAssertTrue(unlockButton.isHittable, "кнопка «Разблокировать» в браузере недоступна")
        assertIncognitoHidden(app, "браузер с замком")
        sleep(1)
        attachScreenshot(app, name: "lock-21-browser-locked")

        unlock(app)
        waitForTitle(app, "Секрет-2")
        XCTAssertTrue(app.webViews.staticTexts["Тайна номер 2"].waitForExistence(timeout: 10),
                      "после разблокировки страница не видна")
        sleep(1)
        attachScreenshot(app, name: "lock-22-browser-unlocked")
    }

    // MARK: - Проверки

    /// Нигде на экране (и в дереве доступности) нет ничего из вкладок инкогнито.
    @MainActor
    private func assertIncognitoHidden(_ app: XCUIApplication, _ context: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let leaked = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                                  "Секрет", "Тайна", "locked.html"))
            .allElementsBoundByIndex
            .map { "\($0.elementType.rawValue) «\($0.label)»\($0.isHittable ? " (доступен)" : "")" }
        if !leaked.isEmpty {
            attachScreenshot(app, name: "leak-\(context)")
        }
        XCTAssertTrue(leaked.isEmpty, "\(context): видно содержимое инкогнито: \(leaked)", file: file, line: line)
        let address = app.textFields["addressBar"]
        if address.exists {
            let value = (address.value as? String) ?? ""
            XCTAssertFalse(value.contains("locked.html") || value.contains("Секрет"),
                           "\(context): адрес инкогнито в адресной строке: \(value)", file: file, line: line)
        }
    }

    /// Раздел «Инкогнито» переключателя заперт: замок с кнопкой, ни одной карточки.
    @MainActor
    private func assertSwitcherLocked(_ app: XCUIApplication, _ context: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let unlockButton = app.buttons["unlockIncognito"]
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 5), "\(context): нет замка", file: file, line: line)
        XCTAssertTrue(unlockButton.exists && unlockButton.isHittable,
                      "\(context): кнопка «Разблокировать» недоступна", file: file, line: line)
        assertIncognitoHidden(app, context, file: file, line: line)
        XCTAssertEqual(app.buttons.matching(identifier: "closeTab").count, 0,
                       "\(context): карточки инкогнито остались в дереве доступности", file: file, line: line)
    }

    // MARK: - Вспомогательное

    /// Запуск с включённым «Face ID для инкогнито»: обычная вкладка hello и две вкладки
    /// инкогнито «Секрет-1» и «Секрет-2» (на экране — вторая).
    @MainActor
    private func launchWithTwoSecrets() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-KentikUITest", "-KentikIncognitoFaceID", "-KentikFakeAuth",
                               "-KentikStartURL", "\(Self.fixtures)/hello.html"]
        app.launch()
        waitForTitle(app, "Kentik Hello", timeout: 300)

        openMenuItem(app, "Новая вкладка инкогнито")
        typeAddress(app, "\(Self.host)/locked.html?n=1")
        waitForTitle(app, "Секрет-1")
        app.buttons["newTabButton"].tap()
        typeAddress(app, "\(Self.host)/locked.html?n=2")
        waitForTitle(app, "Секрет-2")
        XCTAssertEqual(app.buttons["tabsButton"].value as? String, "2", "две вкладки инкогнито")
        return app
    }

    @MainActor
    private func sendToBackgroundAndBack(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        // app.state в симуляторе iOS 26 остаётся «на экране» ещё долго после ухода в фон —
        // просто ждём; что приложение правда было в фоне, видно по запросу Face ID и замку.
        sleep(3)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "приложение не вернулось")
        sleep(1)
    }

    @MainActor
    private func fakeAuthAlert(_ app: XCUIApplication) -> XCUIElement {
        app.alerts["Face ID (тест)"]
    }

    /// «Разблокировать» → тестовый Face ID → «Разрешить»; замок исчезает.
    @MainActor
    private func unlock(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["unlockIncognito"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "нет кнопки «Разблокировать»", file: file, line: line)
        button.tap()
        let alert = fakeAuthAlert(app)
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "«Разблокировать» не спросил Face ID", file: file, line: line)
        alert.buttons["Разрешить"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: button)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "замок не открылся", file: file, line: line)
    }

    @MainActor
    private func waitForTitle(_ app: XCUIApplication, _ expected: String, timeout: TimeInterval = 60,
                              file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts["pageTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: timeout), "нет заголовка страницы", file: file, line: line)
        let waiting = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: title)
        if XCTWaiter().wait(for: [waiting], timeout: timeout) != .completed {
            attachScreenshot(app, name: "fail-\(expected)")
            XCTFail("заголовок «\(title.label)», ждали «\(expected)»", file: file, line: line)
        }
    }

    @MainActor
    private func typeAddress(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields["addressBar"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        let focused = (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
        if !focused { field.tap() }
        field.typeText(text + "\n")
    }

    @MainActor
    private func openMenuItem(_ app: XCUIApplication, _ title: String) {
        app.buttons["menuButton"].tap()
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "нет пункта меню «\(title)»")
        item.tap()
    }

    /// Открыть переключатель вкладок на нужном разделе.
    @MainActor
    @discardableResult
    private func showTabs(_ app: XCUIApplication, incognito: Bool) -> XCUIElement {
        app.buttons["tabsButton"].tap()
        let segment = app.segmentedControls["tabSwitcherSegment"]
        XCTAssertTrue(segment.waitForExistence(timeout: 10), "нет переключателя вкладок")
        segment.buttons.element(boundBy: incognito ? 1 : 0).tap()
        sleep(1)
        return segment
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(data: app.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

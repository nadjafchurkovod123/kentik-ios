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

        // «Новая вкладка инкогнито» из меню при запертом инкогнито сначала спрашивает Face ID;
        // отмена — остаёмся на обычной вкладке, новой вкладки инкогнито нет.
        openMenuItem(app, "Новая вкладка инкогнито")
        let menuAlert = fakeAuthAlert(app)
        XCTAssertTrue(menuAlert.waitForExistence(timeout: 5), "«Новая вкладка инкогнито» не спросила Face ID")
        if menuAlert.exists { menuAlert.buttons["Отменить"].tap() }
        waitForTitle(app, "Kentik Hello", timeout: 10)
        XCTAssertEqual(app.buttons["tabsButton"].value as? String, "1",
                       "после отмены Face ID открылась вкладка: на экране не обычная вкладка")

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

        // «+» на панели в запертой вкладке инкогнито сначала спрашивает Face ID;
        // отмена — новой вкладки нет.
        app.buttons["newTabButton"].tap()
        let plusAlert = fakeAuthAlert(app)
        XCTAssertTrue(plusAlert.waitForExistence(timeout: 5), "«+» в запертом инкогнито не спросил Face ID")
        assertIncognitoHidden(app, "под запросом Face ID от «+» на панели")
        if plusAlert.exists { plusAlert.buttons["Отменить"].tap() }
        XCTAssertTrue(unlockButton.waitForExistence(timeout: 5), "после отмены «+» нет замка")
        XCTAssertEqual(app.buttons["tabsButton"].value as? String, "2",
                       "после отмены Face ID от «+» вкладок инкогнито не две")

        unlock(app)
        waitForTitle(app, "Секрет-2")
        XCTAssertTrue(app.webViews.staticTexts["Тайна номер 2"].waitForExistence(timeout: 10),
                      "после разблокировки страница не видна")
        sleep(1)
        attachScreenshot(app, name: "lock-22-browser-unlocked")
    }

    /// В поле на странице инкогнито стоит курсор, приложение уходит в фон. Замок забирает
    /// у страницы фокус: по возвращении (и после отмены Face ID) клавиатура не появляется —
    /// ни подсказок автозаполнения, ни ввода в спрятанную страницу; после разблокировки
    /// поле не в фокусе.
    @MainActor
    func testLockTakesFocusFromPageField() {
        let app = launchWithTwoSecrets()
        XCTAssertTrue(app.webViews.staticTexts["Тайна номер 2"].waitForExistence(timeout: 30), "страница не отрисовалась")
        let field = app.webViews.textFields["Поле ввода"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "на странице нет поля")
        field.tap()
        XCTAssertTrue(app.webViews.staticTexts["Поле: в фокусе"].waitForExistence(timeout: 10),
                      "поле страницы не получило фокус")
        field.typeText("abc")
        sleep(1)
        attachScreenshot(app, name: "lock-30-page-field-focused")

        sendToBackgroundAndBack(app)
        let alert = fakeAuthAlert(app)
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "после возвращения Face ID не спросили")
        if alert.exists { alert.buttons["Отменить"].tap() }
        sleep(2)
        attachScreenshot(app, name: "lock-31-page-field-face-id-cancelled")
        XCTAssertTrue(app.buttons["unlockIncognito"].waitForExistence(timeout: 5), "в браузере нет замка")
        assertIncognitoHidden(app, "замок после поля страницы")
        assertNoKeyboard(app, "замок после поля страницы")

        unlock(app)
        XCTAssertTrue(app.webViews.staticTexts["Тайна номер 2"].waitForExistence(timeout: 10),
                      "после разблокировки страница не видна")
        sleep(1)
        attachScreenshot(app, name: "lock-32-page-field-unlocked")
        XCTAssertTrue(app.webViews.staticTexts["Поле: не в фокусе"].exists,
                      "поле страницы осталось в фокусе под замком")
        assertNoKeyboard(app, "после разблокировки")
    }

    /// Открыт «Найти на странице» со словом со страницы, приложение уходит в фон. Замок
    /// закрывает поиск: по возвращении ни поля поиска со словом, ни клавиатуры.
    @MainActor
    func testLockClosesFindInPage() {
        let app = launchWithTwoSecrets()
        XCTAssertTrue(app.webViews.staticTexts["Тайна номер 2"].waitForExistence(timeout: 30), "страница не отрисовалась")
        openMenuItem(app, "Найти на странице")
        sleep(1)
        app.typeText("Тайна")
        sleep(1)
        attachScreenshot(app, name: "lock-40-find-open")
        XCTAssertFalse(findFieldsWithSecret(app).isEmpty, "поиск по странице не открылся со словом «Тайна»")

        sendToBackgroundAndBack(app)
        let alert = fakeAuthAlert(app)
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "после возвращения Face ID не спросили")
        if alert.exists { alert.buttons["Отменить"].tap() }
        sleep(2)
        attachScreenshot(app, name: "lock-41-find-face-id-cancelled")
        XCTAssertTrue(app.buttons["unlockIncognito"].waitForExistence(timeout: 5), "в браузере нет замка")
        let fields = findFieldsWithSecret(app)
        XCTAssertTrue(fields.isEmpty, "поиск по странице со словом остался под замком: \(fields)")
        assertIncognitoHidden(app, "замок после поиска по странице")
        assertNoKeyboard(app, "замок после поиска по странице")

        unlock(app)
        sleep(1)
        attachScreenshot(app, name: "lock-42-find-unlocked")
        XCTAssertTrue(findFieldsWithSecret(app).isEmpty, "поиск по странице пережил замок")
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

    /// Клавиатуры нет (ни для поля страницы, ни для поиска по странице).
    @MainActor
    private func assertNoKeyboard(_ app: XCUIApplication, _ context: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.keyboards.count, 0, "\(context): клавиатура на экране", file: file, line: line)
    }

    /// Поля ввода (в том числе поиск по странице), в которых набрано слово со страницы инкогнито.
    @MainActor
    private func findFieldsWithSecret(_ app: XCUIApplication) -> [String] {
        (app.searchFields.allElementsBoundByIndex + app.textFields.allElementsBoundByIndex)
            .compactMap { $0.value as? String }
            .filter { $0.contains("Тайна") }
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

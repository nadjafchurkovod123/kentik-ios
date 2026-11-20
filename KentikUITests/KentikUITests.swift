import XCTest

/// UI-тесты на фикстурах из tests/fixtures (CI раздаёт их на http://127.0.0.1:8765).
/// Каждый тест прикладывает снимки экрана — их смотрят глазами после прогона CI.
final class KentikUITests: XCTestCase {

    static let fixtures = "http://127.0.0.1:8765"

    override func setUp() {
        super.setUp()
        // Не обрываем тест на первой ошибке, чтобы снимок экрана прикрепился всегда.
        continueAfterFailure = true
    }

    // MARK: - Страница и домашний экран

    @MainActor
    func testHelloPageLoads() {
        let app = launch(startURL: "\(Self.fixtures)/hello.html")
        waitForTitle(app, "Kentik Hello")

        let heading = app.webViews.staticTexts["Привет от Кентика"]
        XCTAssertTrue(heading.waitForExistence(timeout: 30), "страница не отрисовалась")

        attachScreenshot(app, name: "01-hello-page")
    }

    @MainActor
    func testHomeScreenOnEmptyTab() {
        let app = launch(startURL: nil)
        XCTAssertTrue(app.descendants(matching: .any)["homeView"].waitForExistence(timeout: 60), "нет домашнего экрана")
        XCTAssertTrue(app.textFields["addressBar"].exists, "нет адресной строки")
        XCTAssertTrue(app.buttons["shieldButton"].exists, "нет кнопки щита")
        XCTAssertTrue(app.buttons["tabsButton"].exists, "нет кнопки вкладок")
        attachScreenshot(app, name: "02-home-empty")
    }

    @MainActor
    func testHomeShowsFrequentTile() {
        let app = launch(startURL: "\(Self.fixtures)/hello.html")
        waitForTitle(app, "Kentik Hello")

        app.buttons["newTabButton"].tap()
        let cancel = app.buttons["cancelEditing"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "новая вкладка не поставила фокус в адрес")
        cancel.tap()

        XCTAssertTrue(app.descendants(matching: .any)["homeView"].waitForExistence(timeout: 10), "нет домашнего экрана")
        XCTAssertTrue(app.buttons["homeTile"].waitForExistence(timeout: 10), "нет плитки частого сайта")
        XCTAssertEqual(app.buttons["tabsButton"].value as? String, "2")
        attachScreenshot(app, name: "03-home-tiles")
    }

    // MARK: - Ввод адреса

    @MainActor
    func testTypingURL() {
        let app = launch(startURL: nil)
        let field = app.textFields["addressBar"]
        XCTAssertTrue(field.waitForExistence(timeout: 60))
        field.tap()
        field.typeText("127.0.0.1:8765/hel")
        XCTAssertTrue(app.buttons["cancelEditing"].waitForExistence(timeout: 5), "нет кнопки «Отмена» при вводе")
        attachScreenshot(app, name: "04-typing")

        field.typeText("lo.html\n")
        waitForTitle(app, "Kentik Hello")
        XCTAssertTrue(app.webViews.staticTexts["Привет от Кентика"].waitForExistence(timeout: 30))
        attachScreenshot(app, name: "05-typed-page")
    }

    // MARK: - Вкладки и инкогнито

    @MainActor
    func testTabSwitcherWithIncognito() {
        let app = launch(startURL: "\(Self.fixtures)/hello.html")
        waitForTitle(app, "Kentik Hello")

        app.buttons["newTabButton"].tap()
        typeAddress(app, "127.0.0.1:8765/links.html")
        waitForTitle(app, "Kentik Links")

        app.buttons["newTabButton"].tap()
        typeAddress(app, "127.0.0.1:8765/article.html")
        waitForTitle(app, "Акулы и короны — Kentik")
        XCTAssertEqual(app.buttons["tabsButton"].value as? String, "3")

        // Инкогнито через меню.
        app.buttons["menuButton"].tap()
        let newIncognito = app.buttons["Новая вкладка инкогнито"]
        XCTAssertTrue(newIncognito.waitForExistence(timeout: 10), "нет пункта «Новая вкладка инкогнито»")
        newIncognito.tap()
        typeAddress(app, "127.0.0.1:8765/hello.html")
        waitForTitle(app, "Kentik Hello")
        XCTAssertEqual(app.buttons["tabsButton"].value as? String, "1", "счётчик инкогнито")
        attachScreenshot(app, name: "06-incognito-page")

        // Вторая вкладка инкогнито — «+» в инкогнито открывает инкогнито.
        app.buttons["newTabButton"].tap()
        let cancel = app.buttons["cancelEditing"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(app.descendants(matching: .any)["incognitoHome"].waitForExistence(timeout: 10),
                      "нет карточки инкогнито на домашнем экране")
        XCTAssertEqual(app.buttons["tabsButton"].value as? String, "2")
        attachScreenshot(app, name: "07-incognito-home")

        app.buttons["tabsButton"].tap()
        let segment = app.segmentedControls["tabSwitcherSegment"]
        XCTAssertTrue(segment.waitForExistence(timeout: 10), "нет переключателя вкладок")
        XCTAssertTrue(segment.buttons.element(boundBy: 1).label.contains("2"), "инкогнито: \(segment.buttons.element(boundBy: 1).label)")
        sleep(1)
        attachScreenshot(app, name: "08-switcher-incognito")

        segment.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(segment.buttons.element(boundBy: 0).label.contains("3"), "обычные: \(segment.buttons.element(boundBy: 0).label)")
        sleep(1)
        attachScreenshot(app, name: "09-switcher-tabs")
    }

    @MainActor
    func testLongPressOpensBackgroundTab() {
        let app = launch(startURL: "\(Self.fixtures)/links.html")
        waitForTitle(app, "Kentik Links")
        let tabs = app.buttons["tabsButton"]
        XCTAssertEqual(tabs.value as? String, "1")

        let link = app.webViews.links["Открыть Hello"]
        XCTAssertTrue(link.waitForExistence(timeout: 30), "нет ссылки на странице")
        link.press(forDuration: 1.5)

        let background = app.buttons["Открыть в фоновой вкладке"]
        XCTAssertTrue(background.waitForExistence(timeout: 10), "нет меню ссылки")
        XCTAssertTrue(app.buttons["Открыть в инкогнито"].exists)
        XCTAssertTrue(app.buttons["Копировать ссылку"].exists)
        attachScreenshot(app, name: "10-link-menu")
        background.tap()

        let two = expectation(for: NSPredicate(format: "value == %@", "2"), evaluatedWith: tabs)
        wait(for: [two], timeout: 10)
        XCTAssertEqual(app.staticTexts["pageTitle"].label, "Kentik Links", "текущая страница сменилась")
        attachScreenshot(app, name: "11-background-opened")
    }

    // MARK: - Щит

    @MainActor
    func testShieldSheet() {
        let app = launch(startURL: "\(Self.fixtures)/hello.html")
        waitForTitle(app, "Kentik Hello")
        XCTAssertEqual(app.buttons["shieldButton"].value as? String, "включена")

        app.buttons["shieldButton"].tap()
        let global = app.switches["shieldGlobalSwitch"]
        XCTAssertTrue(global.waitForExistence(timeout: 10), "шторка щита не открылась")
        XCTAssertTrue(app.switches["shieldSiteSwitch"].exists)
        sleep(1)
        attachScreenshot(app, name: "12-shield-sheet")

        app.switches["shieldSiteSwitch"].tap()
        let status = app.staticTexts["shieldStatus"]
        let off = expectation(for: NSPredicate(format: "label BEGINSWITH %@", "Выключена на"), evaluatedWith: status)
        wait(for: [off], timeout: 10)
        attachScreenshot(app, name: "13-shield-site-off")
    }

    // MARK: - Экраны

    @MainActor
    func testSettings() {
        let app = launch(startURL: nil)
        XCTAssertTrue(app.descendants(matching: .any)["homeView"].waitForExistence(timeout: 60))
        openMenuItem(app, "Настройки")
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 10), "настройки не открылись")
        sleep(1)
        attachScreenshot(app, name: "14-settings")

        app.swipeUp()
        sleep(1)
        attachScreenshot(app, name: "15-settings-bottom")

        // Адресная строка наверх.
        app.swipeDown()
        let top = app.buttons["Сверху"]
        if top.waitForExistence(timeout: 5) {
            top.tap()
        }
        app.buttons["settingsDone"].tap()
        XCTAssertTrue(app.textFields["addressBar"].waitForExistence(timeout: 10))
        sleep(1)
        attachScreenshot(app, name: "16-address-top")
    }

    @MainActor
    func testHistory() {
        let app = launch(startURL: "\(Self.fixtures)/hello.html")
        waitForTitle(app, "Kentik Hello")
        typeAddress(app, "127.0.0.1:8765/links.html")
        waitForTitle(app, "Kentik Links")

        openMenuItem(app, "История")
        XCTAssertTrue(app.navigationBars["История"].waitForExistence(timeout: 10), "история не открылась")
        XCTAssertTrue(app.staticTexts["Kentik Hello"].waitForExistence(timeout: 5) ||
                      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Kentik Hello")).firstMatch.exists,
                      "в истории нет страницы")
        sleep(1)
        attachScreenshot(app, name: "17-history")

        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("Links")
            sleep(1)
            attachScreenshot(app, name: "18-history-search")
        }
    }

    @MainActor
    func testReaderMode() {
        let app = launch(startURL: "\(Self.fixtures)/article.html")
        waitForTitle(app, "Акулы и короны — Kentik")
        openMenuItem(app, "Режим чтения")
        let heading = app.staticTexts["Почему акулы носят короны"]
        XCTAssertTrue(heading.waitForExistence(timeout: 15), "режим чтения не открылся")
        XCTAssertFalse(app.staticTexts["РЕКЛАМА — купите лодку!"].exists && app.otherElements["readerView"].exists,
                       "реклама попала в режим чтения")
        sleep(1)
        attachScreenshot(app, name: "19-reader")
    }

    // MARK: - Вспомогательное

    @MainActor
    private func launch(startURL: String?) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-KentikUITest"]
        if let startURL { arguments += ["-KentikStartURL", startURL] }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor
    private func waitForTitle(_ app: XCUIApplication, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let label = app.staticTexts["pageTitle"]
        XCTAssertTrue(label.waitForExistence(timeout: 60), "нет заголовка страницы", file: file, line: line)
        let loaded = expectation(for: NSPredicate(format: "label == %@", title), evaluatedWith: label)
        wait(for: [loaded], timeout: 60)
    }

    /// Ввести адрес в адресную строку и нажать «Перейти».
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

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(data: screenshot.pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import XCTest

/// Проверки перед релизом, которых не было в остальных наборах: изоляция инкогнито,
/// загрузки в «Документы», восстановление вкладок после перезапуска, входы через OAuth.
/// Фикстуры — tests/fixtures (CI раздаёт их на http://127.0.0.1:8765).
final class MatrixUITests: XCTestCase {

    static let host = "127.0.0.1:8765"
    static let fixtures = "http://\(host)"

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    // MARK: - Инкогнито

    /// Кука, поставленная в инкогнито, видна другим вкладкам инкогнито, не видна обычным
    /// и исчезает, когда закрыта последняя вкладка инкогнито. Страница из инкогнито не
    /// попадает в историю.
    @MainActor
    func testIncognitoCookieIsIsolatedAndForgotten() {
        let app = launch(["-KentikStartURL", "\(Self.fixtures)/cookie.html"])
        waitForTitle(app, "COOKIE no", timeout: 300)

        // Инкогнито ставит куку.
        openMenuItem(app, "Новая вкладка инкогнито")
        typeAddress(app, "\(Self.host)/secret.html")
        waitForTitle(app, "Kentik Secret · COOKIE yes")
        attachScreenshot(app, name: "01-incognito-sets-cookie")

        // Вторая вкладка инкогнито видит ту же куку (одна сессия инкогнито).
        app.buttons["newTabButton"].tap()
        typeAddress(app, "\(Self.host)/cookie.html?second-incognito")
        waitForTitle(app, "COOKIE yes")
        XCTAssertEqual(app.buttons["tabsButton"].value as? String, "2", "две вкладки инкогнито")
        attachScreenshot(app, name: "02-second-incognito-sees-cookie")

        // Обычная вкладка куки не видит.
        showTabs(app, incognito: false)
        app.buttons["doneTabs"].tap()
        typeAddress(app, "\(Self.host)/cookie.html?normal")
        waitForTitle(app, "COOKIE no")
        attachScreenshot(app, name: "03-normal-tab-no-cookie")

        // Закрываем все вкладки инкогнито — сессия стирается.
        let segment = showTabs(app, incognito: true)
        XCTAssertTrue(segment.buttons.element(boundBy: 1).label.contains("2"),
                      "инкогнито: \(segment.buttons.element(boundBy: 1).label)")
        app.buttons["closeAllTabs"].tap()
        let confirm = app.buttons["Закрыть все вкладки инкогнито (2)"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "нет подтверждения «Закрыть все»")
        confirm.tap()
        let zero = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "· 0"),
                                             object: segment.buttons.element(boundBy: 1))
        XCTAssertEqual(XCTWaiter().wait(for: [zero], timeout: 10), .completed, "вкладки инкогнито не закрылись")
        sleep(1)
        attachScreenshot(app, name: "04-incognito-closed")

        // «Готово» на пустом списке инкогнито открывает новую вкладку инкогнито.
        app.buttons["doneTabs"].tap()
        typeAddress(app, "\(Self.host)/cookie.html?new-incognito")
        waitForTitle(app, "COOKIE no")
        XCTAssertEqual(app.buttons["tabsButton"].value as? String, "1", "одна новая вкладка инкогнито")
        attachScreenshot(app, name: "05-new-incognito-no-cookie")

        // История: обычные страницы есть, страницы из инкогнито — нет.
        showTabs(app, incognito: false)
        app.buttons["doneTabs"].tap()
        waitForTitle(app, "COOKIE no")
        openMenuItem(app, "История")
        XCTAssertTrue(app.navigationBars["История"].waitForExistence(timeout: 10), "история не открылась")
        let rows = app.descendants(matching: .any).matching(identifier: "historyRow")
        let normalRow = rows.matching(NSPredicate(format: "label CONTAINS %@", "cookie.html?normal")).firstMatch
        XCTAssertTrue(normalRow.waitForExistence(timeout: 10), "обычной страницы нет в истории")
        // Смотрим только строки истории: под шторкой остаётся браузер, и его элементы
        // (подписи вкладок, значок инкогнито) давали ложное срабатывание.
        let secret = rows.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                               "secret", "incognito"))
        let leaked = secret.allElementsBoundByIndex.map { $0.label }
        XCTAssertEqual(leaked.count, 0, "страница из инкогнито попала в историю: \(leaked)")
        let all = rows.allElementsBoundByIndex.map { $0.label }
        XCTAssertEqual(all.count, 2, "в истории ждали две обычные страницы, строки: \(all)")
        sleep(1)
        attachScreenshot(app, name: "06-history-without-incognito")
    }

    // MARK: - Загрузки

    /// Файл, который страница не может показать, скачивается в «Документы» и виден
    /// в списке загрузок; текущая страница остаётся на месте.
    @MainActor
    func testDownloadGoesToDocuments() {
        let app = launch(["-KentikStartURL", "\(Self.fixtures)/downloads.html"])
        waitForTitle(app, "Kentik Downloads", timeout: 300)

        let link = app.webViews.links["Скачать файл"]
        XCTAssertTrue(link.waitForExistence(timeout: 30), "нет ссылки на файл")
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let toast = app.descendants(matching: .any)["toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 15), "нет уведомления о загрузке")
        attachScreenshot(app, name: "01-download-toast")
        sleep(3)
        XCTAssertEqual(app.staticTexts["pageTitle"].label, "Kentik Downloads", "страница сменилась при загрузке")

        openMenuItem(app, "Загрузки")
        XCTAssertTrue(app.descendants(matching: .any)["downloadsView"].waitForExistence(timeout: 10),
                      "список загрузок не открылся")
        let file = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "kentik-test")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15), "скачанного файла нет в «Документах»")
        sleep(1)
        attachScreenshot(app, name: "02-downloads-list")
    }

    // MARK: - Восстановление вкладок

    /// После перезапуска возвращаются обычные вкладки, вкладки инкогнито — нет.
    @MainActor
    func testSessionRestoresNormalTabsOnly() {
        let app = launch(["-KentikPersistSession", "-KentikStartURL", "\(Self.fixtures)/hello.html"])
        waitForTitle(app, "Kentik Hello", timeout: 300)

        app.buttons["newTabButton"].tap()
        typeAddress(app, "\(Self.host)/links.html")
        waitForTitle(app, "Kentik Links")

        openMenuItem(app, "Новая вкладка инкогнито")
        typeAddress(app, "\(Self.host)/article.html")
        waitForTitle(app, "Акулы и короны — Kentik")
        attachScreenshot(app, name: "01-before-restart-incognito")

        // Уход в фон сохраняет сессию; потом приложение выгружается.
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.terminate()

        let restarted = launch(["-KentikPersistSession"])
        waitForTitle(restarted, "Kentik Hello", timeout: 120)
        XCTAssertEqual(restarted.buttons["tabsButton"].value as? String, "2", "восстановились не две обычные вкладки")
        attachScreenshot(restarted, name: "02-after-restart")

        restarted.buttons["tabsButton"].tap()
        let segment = restarted.segmentedControls["tabSwitcherSegment"]
        XCTAssertTrue(segment.waitForExistence(timeout: 10), "нет переключателя вкладок")
        XCTAssertTrue(segment.buttons.element(boundBy: 0).label.contains("2"),
                      "обычные: \(segment.buttons.element(boundBy: 0).label)")
        XCTAssertTrue(segment.buttons.element(boundBy: 1).label.contains("0"),
                      "инкогнито восстановилось: \(segment.buttons.element(boundBy: 1).label)")
        sleep(1)
        attachScreenshot(restarted, name: "03-restored-switcher")
    }

    // MARK: - Входы через OAuth

    /// Окно входа через Google (window.open на accounts.google.com) открывается вкладкой.
    @MainActor
    func testOAuthPopupIsAllowed() {
        let app = launch(["-KentikStartURL", "\(Self.fixtures)/popups/oauth.html"])
        waitForTitle(app, "Kentik OAuth", timeout: 300)

        let button = app.webViews.buttons["Войти в окне"]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "нет кнопки входа")
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let two = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "2"),
                                            object: app.buttons["tabsButton"])
        XCTAssertEqual(XCTWaiter().wait(for: [two], timeout: 20), .completed, "окно входа не открылось")
        XCTAssertFalse(app.descendants(matching: .any)["popupBlockedBar"].exists, "окно входа заблокировано")
        sleep(4)
        attachScreenshot(app, name: "oauth-popup-opened")
    }

    /// Переход скриптом (без касания ссылки) на accounts.google.com не отменяется.
    @MainActor
    func testOAuthRedirectIsAllowed() {
        let app = launch(["-KentikStartURL", "\(Self.fixtures)/popups/oauth.html"])
        waitForTitle(app, "Kentik OAuth", timeout: 300)

        let button = app.webViews.buttons["Войти переходом"]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "нет кнопки входа")
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let title = app.staticTexts["pageTitle"]
        let left = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != '' AND NOT (label BEGINSWITH %@)", "Kentik OAuth"), object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [left], timeout: 40), .completed,
                       "переход на вход через Google отменён, заголовок «\(title.label)»")
        XCTAssertFalse(app.descendants(matching: .any)["popupBlockedBar"].exists, "переход на вход заблокирован")
        sleep(4)
        attachScreenshot(app, name: "oauth-redirect-followed")
    }

    // MARK: - Вспомогательное

    @MainActor
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-KentikUITest"] + extra
        app.launch()
        return app
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

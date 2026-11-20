import XCTest

/// Блокировщик рекламы на фикстурах (CI раздаёт tests/fixtures на http://127.0.0.1:8765).
///
/// Страницы сами сообщают результат в заголовке (его показывает элемент pageTitle):
/// ads.html — «ADS img=… css=… ok=…», real-ads.html — «REAL ads=… gtm=…».
/// Настройки щита задаются аргументами запуска (домен аргументов UserDefaults):
/// -shield.enabled NO и -shield.disabledHosts ("127.0.0.1").
final class ShieldUITests: XCTestCase {

    static let fixtures = "http://127.0.0.1:8765"
    static let blocked = "ADS img=blocked css=hidden ok=loaded"
    static let visible = "ADS img=loaded css=visible ok=loaded"

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    // MARK: - Тестовые правила (-KentikTestRules)

    @MainActor
    func testTestRulesBlockImageAndHideElement() {
        let app = launch(page: "ads.html", extra: ["-KentikTestRules"])
        waitForTitle(app, Self.blocked, timeout: 240)
        XCTAssertFalse(app.webViews.staticTexts["РЕКЛАМНЫЙ БЛОК"].exists, "блок .test-ad не спрятан")
        attachScreenshot(app, name: "01-test-rules-blocked")
    }

    @MainActor
    func testGlobalOffShowsAds() {
        let app = launch(page: "ads.html", extra: ["-KentikTestRules", "-shield.enabled", "NO"])
        waitForTitle(app, Self.visible, timeout: 240)
        XCTAssertTrue(app.webViews.staticTexts["РЕКЛАМНЫЙ БЛОК"].exists, "при выключенном щите блок должен быть виден")
        attachScreenshot(app, name: "02-global-off-visible")
    }

    @MainActor
    func testPerSiteOffOnlyOnThatHost() {
        let app = launch(page: "ads.html", extra: ["-KentikTestRules", "-shield.disabledHosts", "(\"127.0.0.1\")"])
        waitForTitle(app, Self.visible, timeout: 240)
        attachScreenshot(app, name: "03-site-off-127.0.0.1-visible")

        // Та же страница на другом хосте (localhost) — щит там включён.
        let link = app.webViews.links["Открыть на localhost"]
        XCTAssertTrue(link.waitForExistence(timeout: 20), "нет ссылки на localhost")
        link.tap()
        waitForTitle(app, Self.blocked, timeout: 60)
        attachScreenshot(app, name: "04-site-off-other-host-blocked")
    }

    /// Выключатель в меню щита: страница перезагружается и реклама появляется.
    @MainActor
    func testShieldMenuToggleReloadsPage() {
        let app = launch(page: "ads.html", extra: ["-KentikTestRules"])
        waitForTitle(app, Self.blocked, timeout: 240)

        let shield = app.buttons["shieldButton"]
        XCTAssertTrue(shield.waitForExistence(timeout: 10), "нет кнопки щита")
        shield.tap()
        let item = app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "Блокировка рекламы", "shieldButton")
        ).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "нет пункта «Блокировка рекламы» в меню")
        attachScreenshot(app, name: "05-shield-menu")
        item.tap()
        waitForTitle(app, Self.visible, timeout: 60)
        attachScreenshot(app, name: "06-shield-off-after-toggle")
    }

    // MARK: - Настоящие списки (нужен интернет)

    @MainActor
    func testRealListsBlockGoogleAds() {
        let app = launch(page: "real-ads.html", extra: [])
        waitForTitle(app, "REAL ads=blocked gtm=blocked", timeout: 300)
        attachScreenshot(app, name: "07-real-lists-blocked")
    }

    @MainActor
    func testRealListsOffLoadGoogleAds() {
        let app = launch(page: "real-ads.html", extra: ["-shield.enabled", "NO"])
        let title = app.staticTexts["pageTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 120), "нет заголовка страницы")
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "REAL ads="),
            object: title
        )
        XCTAssertEqual(XCTWaiter().wait(for: [finished], timeout: 180), .completed, "страница не сообщила результат")
        let label = title.label
        XCTAssertFalse(label.contains("ads=blocked"), "без щита adsbygoogle.js должен загрузиться: \(label)")
        XCTAssertFalse(label.contains("gtm=blocked"), "без щита gtag/js должен загрузиться: \(label)")
        attachScreenshot(app, name: "08-real-lists-off-loaded")
    }

    // MARK: - Вспомогательное

    @MainActor
    private func launch(page: String, extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-KentikUITest", "-KentikStartURL", "\(Self.fixtures)/\(page)"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func waitForTitle(_ app: XCUIApplication, _ expected: String, timeout: TimeInterval) {
        let title = app.staticTexts["pageTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 60), "нет заголовка страницы")
        let predicate = NSPredicate(format: "label == %@", expected)
        let waiting = XCTNSPredicateExpectation(predicate: predicate, object: title)
        if XCTWaiter().wait(for: [waiting], timeout: timeout) != .completed {
            XCTFail("ждали заголовок «\(expected)», а он «\(title.label)»")
            attachScreenshot(app, name: "fail-\(expected)")
        }
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(data: app.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

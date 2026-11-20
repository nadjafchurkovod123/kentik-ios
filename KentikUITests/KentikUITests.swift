import XCTest

/// UI-тесты на фикстурах из tests/fixtures (CI раздаёт их на http://127.0.0.1:8765).
final class KentikUITests: XCTestCase {

    static let fixtures = "http://127.0.0.1:8765"

    override func setUp() {
        super.setUp()
        // Не обрываем тест на первой ошибке, чтобы снимок экрана прикрепился всегда.
        continueAfterFailure = true
    }

    @MainActor
    func testHelloPageLoads() {
        let app = launch(startURL: "\(Self.fixtures)/hello.html")

        let title = app.staticTexts["pageTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 60), "нет заголовка страницы")
        let titleLoaded = expectation(for: NSPredicate(format: "label == %@", "Kentik Hello"),
                                      evaluatedWith: title)
        wait(for: [titleLoaded], timeout: 60)

        let heading = app.webViews.staticTexts["Привет от Кентика"]
        XCTAssertTrue(heading.waitForExistence(timeout: 30), "страница не отрисовалась")

        attachScreenshot(app, name: "01-hello-page")
    }

    @MainActor
    func testHomeScreenOnEmptyTab() {
        let app = launch(startURL: nil)
        XCTAssertTrue(app.descendants(matching: .any)["homeView"].waitForExistence(timeout: 60), "нет домашнего экрана")
        XCTAssertTrue(app.textFields["addressBar"].exists, "нет адресной строки")
        attachScreenshot(app, name: "02-home")
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
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(data: screenshot.pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

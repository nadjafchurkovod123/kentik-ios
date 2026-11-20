import XCTest

/// Дымовой прогон на настоящих сайтах с рекламой (нужен интернет). Каждый сайт открывается
/// дважды: с блокировкой (ON) и без неё (OFF), снимки потом складываются рядом
/// (scripts/ci/side_by_side.py). Сайты живые и меняются, поэтому прогон может «моргать»:
/// CI запускает этот набор отдельным шагом, который не валит сборку. Жёстких проверок
/// здесь почти нет — главное снимки.
final class RealSitesUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    /// Крупный российский новостной портал.
    @MainActor
    func testLenta() { compare("lenta", "https://lenta.ru/") }

    /// Российский сайт погоды — известен баннерами на весь экран.
    @MainActor
    func testGismeteo() { compare("gismeteo", "https://www.gismeteo.ru/weather-moscow-4368/") }

    /// Крупный международный новостной сайт с очень плотной рекламой.
    @MainActor
    func testDailyMail() { compare("dailymail", "https://www.dailymail.co.uk/home/index.html") }

    /// Международные новости с видео-рекламой.
    @MainActor
    func testCNN() { compare("cnn", "https://edition.cnn.com/") }

    /// Вики Fandom: видеоплеер с рекламой, баннеры и всплывающие блоки.
    @MainActor
    func testFandomVideo() { compare("fandom", "https://harrypotter.fandom.com/wiki/Harry_Potter") }

    // MARK: - Прогон

    @MainActor
    private func compare(_ name: String, _ url: String) {
        for blocking in [true, false] {
            let mode = blocking ? "ON" : "OFF"
            let app = XCUIApplication()
            app.launchArguments = ["-KentikUITest", "-KentikStartURL", url]
                + (blocking ? [] : ["-shield.enabled", "NO"])
            app.launch()

            waitForPage(app, timeout: blocking ? 300 : 90)
            attachScreenshot(app, name: "\(name)-\(mode)-1-top")

            let web = app.webViews.firstMatch
            if web.exists {
                web.swipeUp(velocity: .slow)
                web.swipeUp(velocity: .slow)
                sleep(4)
                attachScreenshot(app, name: "\(name)-\(mode)-2-scrolled")
                web.swipeUp(velocity: .slow)
                web.swipeUp(velocity: .slow)
                sleep(4)
                attachScreenshot(app, name: "\(name)-\(mode)-3-further")
            }

            let tabs = app.buttons["tabsButton"]
            if tabs.exists, let count = tabs.value as? String {
                // Сайт сам открыл вкладки без касания — для отчёта.
                XCTContext.runActivity(named: "\(name) \(mode): вкладок \(count), заголовок «\(app.staticTexts["pageTitle"].label)»") { _ in }
            }

            if blocking {
                let shield = app.buttons["shieldButton"]
                if shield.waitForExistence(timeout: 5) {
                    shield.tap()
                    if app.switches["shieldGlobalSwitch"].waitForExistence(timeout: 10) {
                        sleep(1)
                        attachScreenshot(app, name: "\(name)-ON-4-shield-stats")
                    }
                }
            }
            app.terminate()
        }
    }

    /// Ждём, пока страница загрузится (полоса загрузки пропадёт), но не дольше лимита:
    /// рекламные сайты часто «грузятся» бесконечно. Потом ещё даём догрузиться рекламе.
    @MainActor
    private func waitForPage(_ app: XCUIApplication, timeout: TimeInterval) {
        let title = app.staticTexts["pageTitle"]
        _ = title.waitForExistence(timeout: timeout)
        // Полоса появляется, когда вкладка начала грузиться (до этого может компилироваться
        // блокировщик — при первом запуске это десятки секунд).
        _ = app.webViews.firstMatch.waitForExistence(timeout: timeout)
        let progress = app.descendants(matching: .any)["progressBar"]
        _ = progress.waitForExistence(timeout: 20)
        let started = Date()
        while progress.exists, Date().timeIntervalSince(started) < 75 {
            sleep(2)
        }
        sleep(10)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(data: app.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

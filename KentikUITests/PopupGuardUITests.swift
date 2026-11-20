import XCTest

/// Защита от всплывающих окон, попандеров и рекламных перенаправлений на фикстурах
/// tests/fixtures/popups (CI раздаёт их на http://127.0.0.1:8765; http://localhost:8765 —
/// «другой сайт», в тестах перенаправлений он же «рекламный хост»).
final class PopupGuardUITests: XCTestCase {

    static let fixtures = "http://127.0.0.1:8765/popups"

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    /// (1) Касание фальшивого плеера, который зовёт window.open: вкладка не открывается,
    /// появляется плашка; «Открыть» — явный выбор пользователя — открывает окно.
    @MainActor
    func testPlayerTapPopupIsBlocked() {
        let app = launch("player.html")
        let title = waitForTitle(app, "Kentik Player")

        tapCenter(of: webText(app, "Плеер"))
        waitForTitle(app, "Kentik Player · нажато")
        let bar = app.descendants(matching: .any)["popupBlockedBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "нет плашки о заблокированном окне")
        XCTAssertTrue(app.staticTexts["popupBlockedText"].label.hasPrefix("Всплывающее окно заблокировано"))
        attachScreenshot(app, name: "01-player-popup-blocked")

        let open = app.buttons["popupBlockedOpen"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "нет кнопки «Открыть»")
        sleep(1)
        XCTAssertEqual(title.label, "Kentik Player · нажато", "открылась новая вкладка")
        open.tap()
        waitForTitle(app, "Kentik Popup Target")
        attachScreenshot(app, name: "02-opened-by-user")
    }

    /// (2) Плеер в iframe с другого сайта открывает попандер по касанию — блокируется.
    @MainActor
    func testIframePlayerPopunderIsBlocked() {
        let app = launch("iframe-host.html")
        let title = waitForTitle(app, "Kentik Iframe Host")

        tapCenter(of: webText(app, "Плеер в iframe"))
        waitForTitle(app, "Kentik Iframe Host · нажато")
        XCTAssertTrue(app.descendants(matching: .any)["popupBlockedBar"].waitForExistence(timeout: 10),
                      "нет плашки о заблокированном окне из iframe")
        sleep(1)
        XCTAssertEqual(title.label, "Kentik Iframe Host · нажато", "попандер из iframe открылся")
        attachScreenshot(app, name: "iframe-popunder-blocked")
    }

    /// (3) setTimeout → location.href на рекламный хост другого сайта — отменяется;
    /// касание ссылки на тот же адрес — проходит.
    @MainActor
    func testTimerRedirectBlockedButTappedLinkAllowed() {
        let app = launch("redirect.html", extra: ["-KentikTestAdHosts", "localhost"])
        // Таймер срабатывает через секунду после загрузки; если переход отменён, страница
        // остаётся и сама меняет заголовок.
        let title = waitForTitle(app, "Kentik Redirect · таймер")
        XCTAssertTrue(app.descendants(matching: .any)["popupBlockedBar"].waitForExistence(timeout: 10),
                      "нет плашки о заблокированном переходе")
        XCTAssertTrue(app.staticTexts["popupBlockedText"].label.hasPrefix("Переход на рекламу заблокирован"))
        sleep(1)
        XCTAssertEqual(title.label, "Kentik Redirect · таймер", "вкладку увело на рекламу")
        attachScreenshot(app, name: "01-timer-redirect-blocked")

        tapCenter(of: webText(app, "Перейти по ссылке", link: true))
        waitForTitle(app, "Kentik Ad Landing")
        attachScreenshot(app, name: "02-tapped-link-allowed")
    }

    /// (4) Касание обычной ссылки target=_blank открывает вкладку.
    @MainActor
    func testNormalBlankLinkOpensTab() {
        let app = launch("links.html")
        waitForTitle(app, "Kentik Links")

        tapCenter(of: webText(app, "Ссылка в новой вкладке", link: true))
        waitForTitle(app, "Kentik Popup Target")
        XCTAssertFalse(app.descendants(matching: .any)["popupBlockedBar"].exists, "обычную ссылку заблокировали")
        attachScreenshot(app, name: "blank-link-opened")
    }

    /// (5) Невидимый слой поверх <video> убирается, касание получает само видео.
    @MainActor
    func testInvisibleOverlayOverVideoIsRemoved() {
        let app = launch("overlay.html")
        waitForTitle(app, "Kentik Overlay")
        let caption = webText(app, "Видео")
        sleep(2)   // рекламный слой появляется через 300 мс после загрузки

        tapCenter(of: caption)
        waitForTitle(app, "Kentik Overlay · видео")
        XCTAssertFalse(app.descendants(matching: .any)["popupBlockedBar"].exists, "касание ушло рекламному слою")
        attachScreenshot(app, name: "overlay-removed-video-tapped")
    }

    /// (6) Щит выключен для сайта — окна ведут себя как обычно.
    @MainActor
    func testShieldOffForSiteAllowsPopups() {
        // Сайт-исключение задаём через UserDefaults (аргумент запуска) — как будто его
        // выключили в меню щита.
        let app = launch("player.html", extra: ["-shield.disabledHosts", "(\"127.0.0.1\")"])
        waitForTitle(app, "Kentik Player")

        tapCenter(of: webText(app, "Плеер"))
        waitForTitle(app, "Kentik Popup Target")
        XCTAssertFalse(app.descendants(matching: .any)["popupBlockedBar"].exists, "плашка при выключенном щите")
        attachScreenshot(app, name: "shield-off-popup-opened")
    }

    /// (7) Скрипт в момент клика подменяет адрес ссылки на рекламный сайт, которого нет
    /// в списках: ни новой вкладки (target=_blank), ни перехода этой вкладки.
    @MainActor
    func testHijackedLinkDoesNotOpenAd() {
        let app = launch("hijack.html")
        let title = waitForTitle(app, "Kentik Hijack")
        let tabs = app.buttons["tabsButton"]

        // «Серия 2»: подмена + target=_blank + stopPropagation (защита в странице не успевает).
        tapCenter(of: webText(app, "Серия 2", link: true))
        waitForTitle(app, "Kentik Hijack · ep2")
        XCTAssertTrue(app.descendants(matching: .any)["popupBlockedBar"].waitForExistence(timeout: 10),
                      "нет плашки о заблокированном окне")
        sleep(1)
        XCTAssertEqual(tabs.value as? String, "1", "открылась вкладка с рекламой")
        XCTAssertEqual(title.label, "Kentik Hijack · ep2")
        attachScreenshot(app, name: "01-hijack-new-tab-blocked")

        // «Серия 3»: защита возвращает ссылке target, но адрес подменён — переход отменяется.
        tapCenter(of: webText(app, "Серия 3", link: true))
        waitForTitle(app, "Kentik Hijack · ep3")
        sleep(2)
        XCTAssertEqual(title.label, "Kentik Hijack · ep3", "вкладку увело на рекламу")
        XCTAssertEqual(tabs.value as? String, "1", "открылась вкладка с рекламой")
        attachScreenshot(app, name: "02-hijack-same-tab-blocked")
    }

    /// (8) Касание плеера меняет location.href на рекламный домен, которого нет в списках:
    /// переход отменяется; «Открыть» — явный выбор — открывает его.
    @MainActor
    func testPlayerTapRedirectToUnlistedSiteIsBlocked() {
        let app = launch("player-redirect.html")
        let title = waitForTitle(app, "Kentik Player Redirect")

        tapCenter(of: webText(app, "Плеер"))
        waitForTitle(app, "Kentik Player Redirect · нажато")
        XCTAssertTrue(app.descendants(matching: .any)["popupBlockedBar"].waitForExistence(timeout: 10),
                      "нет плашки о заблокированном переходе")
        XCTAssertTrue(app.staticTexts["popupBlockedText"].label.hasPrefix("Переход на другой сайт заблокирован"),
                      "текст плашки: \(app.staticTexts["popupBlockedText"].label)")
        sleep(1)
        XCTAssertEqual(title.label, "Kentik Player Redirect · нажато", "вкладку увело на рекламу")
        attachScreenshot(app, name: "01-player-redirect-blocked")

        let open = app.buttons["popupBlockedOpen"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "нет кнопки «Открыть»")
        open.tap()
        waitForTitle(app, "Kentik Ad Landing")
    }

    /// (9) Прозрачная ссылка target=_blank на весь экран: касание текста страницы не
    /// открывает рекламную вкладку, а достаётся тексту.
    @MainActor
    func testInvisibleFullPageLinkIsRemoved() {
        let app = launch("blank-overlay.html")
        waitForTitle(app, "Kentik Blank Overlay")
        let text = webText(app, "Список серий")
        sleep(2)   // ссылка-перехватчик появляется через 300 мс после загрузки

        tapCenter(of: text)
        waitForTitle(app, "Kentik Blank Overlay · текст")
        sleep(1)
        XCTAssertEqual(app.buttons["tabsButton"].value as? String, "1", "открылась рекламная вкладка")
        attachScreenshot(app, name: "blank-overlay-removed")
    }

    // MARK: - Вспомогательное

    @MainActor
    private func launch(_ page: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-KentikUITest", "-KentikStartURL", "\(Self.fixtures)/\(page)"] + extra
        app.launch()
        return app
    }

    @MainActor
    @discardableResult
    private func waitForTitle(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 60,
                              file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let title = app.staticTexts["pageTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: timeout), "нет заголовка страницы", file: file, line: line)
        let predicate = NSPredicate(format: "label == %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: title)], timeout: timeout)
        if result != .completed {
            attachScreenshot(app, name: "fail-title-\(text)")
            XCTFail("заголовок «\(title.label)», ждали «\(text)»", file: file, line: line)
        }
        return title
    }

    @MainActor
    private func webText(_ app: XCUIApplication, _ text: String, link: Bool = false,
                         file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = link ? app.webViews.links[text] : app.webViews.staticTexts[text]
        XCTAssertTrue(element.waitForExistence(timeout: 30), "нет «\(text)» на странице", file: file, line: line)
        return element
    }

    /// Касание по координатам центра: веб-элементы под прозрачными слоями XCTest может
    /// считать «не нажимаемыми», а нам нужно настоящее касание в эту точку.
    @MainActor
    private func tapCenter(of element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(data: app.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

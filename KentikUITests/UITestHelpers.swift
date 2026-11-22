import XCTest
import UIKit

/// Общие шаги UI-тестов 1.0.2 (имена с префиксом k — чтобы не путаться с приватными
/// помощниками старых наборов).
extension XCTestCase {

    static var kFixtures: String { "http://127.0.0.1:8765" }

    @MainActor
    func kLaunch(_ arguments: [String], start: String?, diag: Diag? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-KentikUITest"] + arguments + (start.map { ["-KentikStartURL", $0] } ?? [])
        if let diag { app.launchEnvironment = diag.environment }
        app.launch()
        return app
    }

    @MainActor
    @discardableResult
    func kWaitTitle(_ app: XCUIApplication, _ expected: String, contains: Bool = false, timeout: TimeInterval = 60,
                    file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let title = app.staticTexts["pageTitle"]
        guard title.waitForExistence(timeout: timeout) else {
            XCTFail("нет заголовка страницы", file: file, line: line)
            return false
        }
        let predicate = contains ? NSPredicate(format: "label CONTAINS %@", expected) : NSPredicate(format: "label == %@", expected)
        let ok = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: title)], timeout: timeout) == .completed
        if !ok {
            kShot(app, "fail-title-\(expected)")
            XCTFail("заголовок «\(title.label)», ждали «\(expected)»", file: file, line: line)
        }
        return ok
    }

    @MainActor
    func kTypeAddress(_ app: XCUIApplication, _ text: String) {
        let field = app.textFields["addressBar"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "нет адресной строки")
        let focused = (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
        if !focused { field.tap() }
        field.typeText(text + "\n")
    }

    @MainActor
    func kMenu(_ app: XCUIApplication, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["menuButton"].tap()
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "нет пункта меню «\(title)»", file: file, line: line)
        item.tap()
    }

    @MainActor
    func kFakeAuth(_ app: XCUIApplication) -> XCUIElement {
        app.alerts["Face ID (тест)"]
    }

    /// Ждёт тестовый Face ID и отвечает (allow — «Разрешить», иначе «Отменить»).
    @MainActor
    @discardableResult
    func kAnswerFaceID(_ app: XCUIApplication, allow: Bool, timeout: TimeInterval = 8, _ context: String,
                       file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let alert = kFakeAuth(app)
        let shown = alert.waitForExistence(timeout: timeout)
        XCTAssertTrue(shown, "\(context): Face ID не спросили", file: file, line: line)
        if shown { alert.buttons[allow ? "Разрешить" : "Отменить"].tap() }
        return shown
    }

    @MainActor
    func kBackgroundAndBack(_ app: XCUIApplication, seconds: UInt32 = 3) {
        XCUIDevice.shared.press(.home)
        sleep(seconds)
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        sleep(1)
    }

    @MainActor
    func kShowTabs(_ app: XCUIApplication, incognito: Bool) -> XCUIElement {
        app.buttons["tabsButton"].tap()
        let segment = app.segmentedControls["tabSwitcherSegment"]
        XCTAssertTrue(segment.waitForExistence(timeout: 10), "нет переключателя вкладок")
        segment.buttons.element(boundBy: incognito ? 1 : 0).tap()
        return segment
    }

    @MainActor
    @discardableResult
    func kShot(_ app: XCUIApplication, _ name: String) -> UIImage {
        attachScreen(name)
    }

    /// Средний цвет области экрана (в точках) на снимке.
    @MainActor
    func kAverageColor(_ image: UIImage, in rect: CGRect) -> (r: Double, g: Double, b: Double) {
        guard let cg = image.cgImage else { return (0, 0, 0) }
        let scale = CGFloat(cg.width) / max(image.size.width, 1)
        let pixel = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !pixel.isEmpty, let crop = cg.cropping(to: pixel) else { return (0, 0, 0) }
        let w = 24, h = 24
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0, 0) }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: buffer.count, by: 4) {
            r += Double(buffer[i]); g += Double(buffer[i + 1]); b += Double(buffer[i + 2])
        }
        let n = Double(w * h)
        return (r / n, g / n, b / n)
    }

    /// Фиолетовый: синего и красного заметно больше зелёного.
    func kIsPurple(_ c: (r: Double, g: Double, b: Double)) -> Bool {
        c.b > c.g + 35 && c.r > c.g + 12
    }
}

import XCTest
import WebKit
@testable import Kentik

/// Разбор адресной строки: адрес или поиск в Google.
final class AddressParserTests: XCTestCase {

    func testFullURLIsKeptAsIs() {
        XCTAssertEqual(AddressParser.url(from: "https://example.com/a?b=1")?.absoluteString,
                       "https://example.com/a?b=1")
    }

    func testBareDomainGetsHTTPS() {
        XCTAssertEqual(AddressParser.url(from: "  example.com ")?.absoluteString, "https://example.com")
        XCTAssertEqual(AddressParser.url(from: "m.example.org/path")?.absoluteString, "https://m.example.org/path")
    }

    func testLocalAddressesGetHTTP() {
        XCTAssertEqual(AddressParser.url(from: "127.0.0.1:8765/hello.html")?.absoluteString,
                       "http://127.0.0.1:8765/hello.html")
        XCTAssertEqual(AddressParser.url(from: "localhost:3000")?.absoluteString, "http://localhost:3000")
    }

    func testTextBecomesGoogleSearch() throws {
        let url = try XCTUnwrap(AddressParser.url(from: "сериал онлайн c++"))
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(url.path, "/search")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first
        XCTAssertEqual(query?.name, "q")
        XCTAssertEqual(query?.value, "сериал онлайн c++")
        XCTAssertTrue(url.absoluteString.contains("c%2B%2B"))
    }

    func testSingleWordIsSearch() {
        XCTAssertEqual(AddressParser.url(from: "кентик")?.host, "www.google.com")
    }

    func testEmptyInputGivesNil() {
        XCTAssertNil(AddressParser.url(from: "   "))
    }
}

/// Инкогнито: одна непостоянная сессия на все вкладки, сброс после закрытия последней.
@MainActor
final class IncognitoSessionTests: XCTestCase {

    func testIncognitoTabsShareOneNonPersistentStoreUntilLastIsClosed() {
        let manager = TabManager()
        let first = manager.addTab(incognito: true)
        let second = manager.addTab(incognito: true)
        let normal = manager.addTab(incognito: false)

        let session = WebViewFactory.currentIncognitoDataStore
        XCTAssertFalse(session.isPersistent)
        XCTAssertFalse(first.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(second.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(normal.webView.configuration.websiteDataStore.isPersistent)

        manager.close(first)
        XCTAssertTrue(WebViewFactory.currentIncognitoDataStore === session,
                      "пока открыта хоть одна вкладка инкогнито, сессия та же")

        manager.close(second)
        XCTAssertFalse(WebViewFactory.currentIncognitoDataStore === session,
                       "после последней вкладки инкогнито сессия новая")
        XCTAssertEqual(manager.tabs.count, 1)
        manager.close(normal)
    }

    func testShieldSettingsPerHost() {
        let defaults = UserDefaults(suiteName: "KentikTests-\(UUID().uuidString)")!
        let settings = BlockingSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled(forHost: "www.example.com"))
        settings.setEnabled(false, forHost: "WWW.Example.com")
        XCTAssertFalse(settings.isEnabled(forHost: "example.com"))
        XCTAssertTrue(settings.isEnabled(forHost: "other.com"))
        settings.isEnabledGlobally = false
        XCTAssertFalse(settings.isEnabled(forHost: "other.com"))
    }
}

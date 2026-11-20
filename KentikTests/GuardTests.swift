import XCTest
import WebKit
@testable import Kentik

/// Домены: регистрируемый домен, набор рекламных хостов, входы через OAuth.
final class DomainAndHostsTests: XCTestCase {

    func testRegistrableDomain() {
        XCTAssertEqual(Domain.registrable("www.google.com"), "google.com")
        XCTAssertEqual(Domain.registrable("a.b.example.co.uk"), "example.co.uk")
        XCTAssertEqual(Domain.registrable("Player.Site.RU."), "site.ru")
        XCTAssertEqual(Domain.registrable("127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(Domain.registrable("localhost"), "localhost")
        XCTAssertNil(Domain.registrable(nil))
        XCTAssertTrue(Domain.isCrossSite("127.0.0.1", "localhost"))
        XCTAssertFalse(Domain.isCrossSite("m.site.ru", "cdn.site.ru"))
        XCTAssertFalse(Domain.isCrossSite(nil, "site.ru"))
    }

    func testAdHostsMatchSubdomainsButNotTopLevel() {
        let hosts = AdHosts(hosts: ["popads.net", "ads.example.org", "localhost"])
        XCTAssertTrue(hosts.contains(host: "popads.net"))
        XCTAssertTrue(hosts.contains(host: "c1.POPADS.net"))
        XCTAssertTrue(hosts.contains(host: "x.ads.example.org"))
        XCTAssertFalse(hosts.contains(host: "example.org"))
        XCTAssertFalse(hosts.contains(host: "notpopads.net"))
        XCTAssertFalse(hosts.contains(host: "net"))
        XCTAssertTrue(hosts.contains(host: "localhost"))
        XCTAssertFalse(hosts.contains(host: "127.0.0.1"))
        XCTAssertFalse(hosts.contains(host: nil))
    }

    func testSeedContainsPopunderNetworks() {
        let hosts = AdHosts()
        XCTAssertTrue(hosts.contains(host: "a.popads.net"))
        XCTAssertTrue(hosts.contains(host: "go.adsterra.com"))
        XCTAssertFalse(hosts.contains(host: "google.com"))
    }

    func testLoginHosts() {
        XCTAssertTrue(LoginHosts.contains("accounts.google.com"))
        XCTAssertTrue(LoginHosts.contains("appleid.apple.com"))
        XCTAssertTrue(LoginHosts.contains("oauth.vk.com"))
        XCTAssertTrue(LoginHosts.contains("passport.yandex.kz"))
        XCTAssertTrue(LoginHosts.contains("oauth.telegram.org"))
        XCTAssertFalse(LoginHosts.contains("adservice.google.com"))
        XCTAssertFalse(LoginHosts.contains("popads.net"))
    }
}

/// Решения о новых окнах.
@MainActor
final class PopupGuardTests: XCTestCase {

    private var guardUnderTest: PopupGuard!
    private var shieldOn = true
    private let now = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        guardUnderTest = PopupGuard()
        shieldOn = true
        guardUnderTest.isShieldEnabled = { [unowned self] _, _ in self.shieldOn }
        guardUnderTest.adHosts = AdHosts(hosts: ["popads.net"])
    }

    private func request(_ url: String, link: Bool = true, main: Bool = true) -> PopupGuard.Request {
        PopupGuard.Request(url: URL(string: url), isLinkActivation: link, fromMainFrame: main, pageHost: "serial.example")
    }

    private func tapped(link: String?, secondsAgo: TimeInterval = 0.5) -> TabGuardState {
        var state = TabGuardState()
        state.lastTapAt = now.addingTimeInterval(-secondsAgo)
        if let link {
            state.lastLinkTapAt = state.lastTapAt
            state.lastLinkURL = URL(string: link)
        }
        return state
    }

    private func isBlocked(_ decision: PopupDecision) -> Bool {
        if case .block = decision { return true }
        return false
    }

    func testRealTapOnBlankLinkOpensTab() {
        let decision = guardUnderTest.evaluate(request("https://news.example/a"),
                                               state: tapped(link: "https://news.example/a"), now: now)
        XCTAssertEqual(decision, .allowNewTab(background: false))
    }

    func testLinkActivationWithoutTapIsBlocked() {
        XCTAssertTrue(isBlocked(guardUnderTest.evaluate(request("https://news.example/a"), state: TabGuardState(), now: now)))
        // Касание было давно.
        let stale = tapped(link: "https://news.example/a", secondsAgo: 10)
        XCTAssertTrue(isBlocked(guardUnderTest.evaluate(request("https://news.example/a"), state: stale, now: now)))
    }

    func testTapOnPlayerThatCallsWindowOpenIsBlocked() {
        // Касание не по ссылке (плеер), окно — window.open.
        let decision = guardUnderTest.evaluate(request("https://news.example/promo", link: false),
                                               state: tapped(link: nil), now: now)
        XCTAssertTrue(isBlocked(decision))
    }

    func testSyntheticLinkClickAfterPlayerTapIsBlocked() {
        // Скрипт кликает созданную ссылку target=_blank, хотя касались плеера.
        let decision = guardUnderTest.evaluate(request("https://promo.example/"), state: tapped(link: nil), now: now)
        XCTAssertTrue(isBlocked(decision))
    }

    func testPopupFromIframeIsBlocked() {
        let decision = guardUnderTest.evaluate(request("https://news.example/a", main: false),
                                               state: tapped(link: "https://news.example/a"), now: now)
        XCTAssertTrue(isBlocked(decision))
    }

    func testAdHostIsBlockedEvenAfterRealTap() {
        let decision = guardUnderTest.evaluate(request("https://c1.popads.net/x"),
                                               state: tapped(link: "https://c1.popads.net/x"), now: now)
        XCTAssertTrue(isBlocked(decision))
    }

    func testWindowOpenOfTappedLinkIsAllowed() {
        let decision = guardUnderTest.evaluate(request("https://news.example/a#top", link: false),
                                               state: tapped(link: "https://news.example/a"), now: now)
        XCTAssertEqual(decision, .allowNewTab(background: false))
    }

    func testHijackedLinkCannotOpenOtherSite() {
        // Касались ссылки на серию, а скрипт в момент клика подменил href на рекламу.
        let decision = guardUnderTest.evaluate(request("https://fresh-ad.example/landing"),
                                               state: tapped(link: "https://serial.example/ep2"), now: now)
        XCTAssertTrue(isBlocked(decision))
        // Ссылка на тот же сайт (другая страница) — можно.
        XCTAssertEqual(guardUnderTest.evaluate(request("https://serial.example/ep3"),
                                               state: tapped(link: "https://www.serial.example/ep2"), now: now),
                       .allowNewTab(background: false))
    }

    func testOAuthPopupIsAllowedFromIframe() {
        let decision = guardUnderTest.evaluate(request("https://accounts.google.com/o/oauth2/auth", link: false, main: false),
                                               state: tapped(link: nil), now: now)
        XCTAssertEqual(decision, .allowNewTab(background: false))
    }

    func testBlankWindowIsBlocked() {
        XCTAssertTrue(isBlocked(guardUnderTest.evaluate(request("about:blank", link: false), state: tapped(link: nil), now: now)))
        let empty = PopupGuard.Request(url: nil, isLinkActivation: false, fromMainFrame: true, pageHost: "a.example")
        XCTAssertTrue(isBlocked(guardUnderTest.evaluate(empty, state: tapped(link: nil), now: now)))
    }

    func testShieldOffForSiteAllowsEverything() {
        shieldOn = false
        let decision = guardUnderTest.evaluate(request("https://c1.popads.net/x", link: false, main: false),
                                               state: TabGuardState(), now: now)
        XCTAssertEqual(decision, .allowNewTab(background: false))
    }
}

/// Решения о переходах главного фрейма.
@MainActor
final class RedirectGuardTests: XCTestCase {

    private var guardUnderTest: RedirectGuard!
    private var shieldOn = true
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let page = URL(string: "https://serial.example/episode/1")!

    override func setUp() {
        super.setUp()
        guardUnderTest = RedirectGuard()
        shieldOn = true
        guardUnderTest.isShieldEnabled = { [unowned self] _, _ in self.shieldOn }
        guardUnderTest.adHosts = AdHosts(hosts: ["popads.net", "adsterra.com"])
    }

    private func nav(_ url: String, type: WKNavigationType = .other, main: Bool = true,
                     from page: URL? = nil, redirect: Bool = false) -> RedirectGuard.Request {
        RedirectGuard.Request(url: URL(string: url), type: type, targetsMainFrame: true,
                              fromMainFrame: main, pageURL: page ?? self.page, isRedirect: redirect)
    }

    private func linkTap(_ link: String, secondsAgo: TimeInterval = 0.4, on pageHost: String = "serial.example") -> TabGuardState {
        var state = TabGuardState()
        state.lastTapAt = now.addingTimeInterval(-secondsAgo)
        state.lastLinkTapAt = state.lastTapAt
        state.lastLinkURL = URL(string: link)
        state.lastLinkTapPageHost = pageHost
        return state
    }

    func testScriptRedirectToUnlistedSiteIsCancelled() {
        // Рекламные домены меняются каждый день: без касания ссылки на другой сайт не уводим.
        var state = TabGuardState()
        XCTAssertTrue(isCancel(guardUnderTest.evaluate(nav("https://fresh-ad.xyz/r"), state: &state, now: now)))
        // Касание плеера (не ссылки) — тоже.
        state.lastTapAt = now.addingTimeInterval(-0.3)
        XCTAssertTrue(isCancel(guardUnderTest.evaluate(nav("https://fresh-ad.xyz/r"), state: &state, now: now)))
        // Форма на другой сайт после касания кнопки — тоже; вход через OAuth — можно.
        XCTAssertTrue(isCancel(guardUnderTest.evaluate(nav("https://fresh-ad.xyz/f", type: .formSubmitted), state: &state, now: now)))
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://accounts.google.com/o/oauth2", type: .formSubmitted), state: &state, now: now), .allow)
    }

    func testHijackedLinkToUnlistedSiteIsCancelled() {
        var state = linkTap("https://serial.example/episode/2")
        XCTAssertTrue(isCancel(guardUnderTest.evaluate(nav("https://fresh-ad.xyz/landing", type: .linkActivated),
                                                       state: &state, now: now)))
        // Сама ссылка на другой сайт — можно.
        var other = linkTap("https://news.example/story")
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://news.example/story", type: .linkActivated), state: &other, now: now), .allow)
    }

    func testServerRedirectToUnlistedSiteIsAllowed() {
        // Зеркало сайта или сокращатель ссылки отвечает 301/302 — это не скрипт страницы.
        var state = TabGuardState()
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://mirror.example/", redirect: true), state: &state, now: now), .allow)
        XCTAssertTrue(isCancel(guardUnderTest.evaluate(nav("https://go.popads.net/r", redirect: true), state: &state, now: now)),
                      "серверное перенаправление на рекламный хост — отменяется")
    }

    func testOutboundLinkInterstitialMayForward() {
        // Касание ссылки на сокращатель (другой сайт) → его страница скриптом ведёт дальше.
        var state = linkTap("https://short.example/abc", secondsAgo: 1.5)
        state.lastCommitAt = now.addingTimeInterval(-0.5)
        let short = URL(string: "https://short.example/abc")!
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://dest.example/article", from: short), state: &state, now: now), .allow)
        // Но не на рекламный хост.
        XCTAssertTrue(isCancel(guardUnderTest.evaluate(nav("https://go.popads.net/r", from: short), state: &state, now: now)))
    }

    func testAwayPageOfSameSiteForwardsOnlyToNamedDestination() {
        // Внутренняя ссылка «/away?to=…» сайта: дальше можно только туда, куда она указывает.
        var state = linkTap("https://serial.example/away?to=https%3A%2F%2Fdest.example%2Fx", secondsAgo: 1)
        state.lastCommitAt = now.addingTimeInterval(-0.4)
        let away = URL(string: "https://serial.example/away?to=https%3A%2F%2Fdest.example%2Fx")!
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://dest.example/x", from: away), state: &state, now: now), .allow)
        XCTAssertTrue(isCancel(guardUnderTest.evaluate(nav("https://fresh-ad.xyz/", from: away), state: &state, now: now)))
    }

    func testEpisodePageOpenedByTapCannotRedirectOnLoad() {
        // Касание внутренней ссылки на серию, страница серии при загрузке уводит на рекламу.
        var state = linkTap("https://serial.example/episode/2", secondsAgo: 1)
        state.lastCommitAt = now.addingTimeInterval(-0.5)
        let episode = URL(string: "https://serial.example/episode/2")!
        XCTAssertTrue(isCancel(guardUnderTest.evaluate(nav("https://fresh-ad.xyz/", from: episode), state: &state, now: now)))
    }

    private func isCancel(_ verdict: RedirectGuard.Verdict) -> Bool {
        if case .cancel = verdict { return true }
        return false
    }

    func testScriptRedirectToAdHostIsCancelled() {
        var state = TabGuardState()
        XCTAssertTrue(isCancel(guardUnderTest.evaluate(nav("https://go.popads.net/r"), state: &state, now: now)))
    }

    func testUserTappedLinkToAdHostIsAllowed() {
        var state = TabGuardState()
        state.lastTapAt = now.addingTimeInterval(-0.4)
        state.lastLinkTapAt = state.lastTapAt
        state.lastLinkURL = URL(string: "https://go.popads.net/r")
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://go.popads.net/r", type: .linkActivated), state: &state, now: now), .allow)
    }

    func testHijackedLinkTapToAdHostIsCancelled() {
        // Коснулись ссылки на сам сайт, а скрипт увёл на рекламу.
        var state = TabGuardState()
        state.lastTapAt = now.addingTimeInterval(-0.4)
        state.lastLinkTapAt = state.lastTapAt
        state.lastLinkURL = URL(string: "https://serial.example/episode/2")
        XCTAssertTrue(isCancel(guardUnderTest.evaluate(nav("https://adsterra.com/x"), state: &state, now: now)))
    }

    func testTapOnPlayerThenRedirectToAdHostIsCancelled() {
        var state = TabGuardState()
        state.lastTapAt = now.addingTimeInterval(-0.2)   // касание плеера, не ссылки
        XCTAssertTrue(isCancel(guardUnderTest.evaluate(nav("https://go.popads.net/r"), state: &state, now: now)))
    }

    func testSameSiteNavigationIsAllowed() {
        var state = TabGuardState()
        let onAd = URL(string: "https://www.popads.net/")!
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://popads.net/help", from: onAd), state: &state, now: now), .allow)
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://serial.example/episode/2"), state: &state, now: now), .allow)
    }

    func testOAuthRedirectsAreAllowed() {
        var state = TabGuardState()
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://accounts.google.com/o/oauth2/auth", main: false), state: &state, now: now), .allow)
        let fromGoogle = URL(string: "https://accounts.google.com/signin")!
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://serial.example/auth/cb", from: fromGoogle), state: &state, now: now), .allow)
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://oauth.vk.com/authorize"), state: &state, now: now), .allow)
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://passport.yandex.ru/auth"), state: &state, now: now), .allow)
    }

    func testIframeTopNavigationToOtherSiteIsCancelled() {
        var state = TabGuardState()
        XCTAssertTrue(isCancel(guardUnderTest.evaluate(nav("https://promo.example/", main: false), state: &state, now: now)))
        // Касание ссылки внутри фрейма (target=_top) — можно.
        state.lastTapAt = now
        state.lastLinkTapAt = now
        state.lastLinkURL = URL(string: "https://promo.example/")
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://promo.example/", type: .linkActivated, main: false), state: &state, now: now), .allow)
    }

    func testRapidRedirectChainIsStopped() {
        var state = TabGuardState()
        var verdicts: [RedirectGuard.Verdict] = []
        var from = page
        for i in 0..<6 {
            let url = "https://hop\(i).example/x"
            verdicts.append(guardUnderTest.evaluate(nav(url, from: from, redirect: true), state: &state,
                                                    now: now.addingTimeInterval(Double(i))))
            from = URL(string: url)!
        }
        XCTAssertEqual(Array(verdicts.prefix(4)), Array(repeating: .allow, count: 4))
        XCTAssertTrue(isCancel(verdicts[4]))
    }

    func testInterstitialLoopIsStopped() {
        var state = TabGuardState()
        let a = URL(string: "https://click.example/continue")!
        let b = URL(string: "https://serial.example/episode/1")!
        // b → a → b → a → b (серверные перенаправления): третий заход на тот же адрес отменяется.
        XCTAssertEqual(guardUnderTest.evaluate(nav(a.absoluteString, from: b, redirect: true), state: &state, now: now), .allow)
        XCTAssertEqual(guardUnderTest.evaluate(nav(b.absoluteString, from: a, redirect: true), state: &state, now: now.addingTimeInterval(1)), .allow)
        XCTAssertEqual(guardUnderTest.evaluate(nav(a.absoluteString + "?t=2", from: b, redirect: true), state: &state, now: now.addingTimeInterval(2)), .allow)
        XCTAssertTrue(isCancel(guardUnderTest.evaluate(nav(b.absoluteString, from: a, redirect: true), state: &state, now: now.addingTimeInterval(3)))
                      || isCancel(guardUnderTest.evaluate(nav(a.absoluteString, from: b, redirect: true), state: &state, now: now.addingTimeInterval(4))))
    }

    func testUserActionResetsChain() {
        var state = TabGuardState()
        for i in 0..<4 {
            _ = guardUnderTest.evaluate(nav("https://hop\(i).example/", redirect: true), state: &state, now: now)
        }
        XCTAssertFalse(state.autoNavigations.isEmpty)
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://serial.example/", type: .backForward), state: &state, now: now), .allow)
        XCTAssertTrue(state.autoNavigations.isEmpty)
    }

    func testAppIntentAllowsTypedAdHost() {
        var state = TabGuardState()
        state.appIntentAt = now.addingTimeInterval(-1)
        state.appIntentURL = URL(string: "https://popads.net/")
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://popads.net/"), state: &state, now: now), .allow)
    }

    func testShieldOffAllowsEverything() {
        shieldOn = false
        var state = TabGuardState()
        XCTAssertEqual(guardUnderTest.evaluate(nav("https://go.popads.net/r", main: false), state: &state, now: now), .allow)
    }

    func testSubframeNavigationsAreIgnored() {
        var state = TabGuardState()
        let request = RedirectGuard.Request(url: URL(string: "https://go.popads.net/r"), type: .other,
                                            targetsMainFrame: false, fromMainFrame: false, pageURL: page)
        XCTAssertEqual(guardUnderTest.evaluate(request, state: &state, now: now), .allow)
    }
}

/// Скриплеты и их установка в веб-вью.
@MainActor
final class GuardInstallerTests: XCTestCase {

    private var savedProvider: (@MainActor (Bool) -> Scriptlets.Config)!

    override func setUp() {
        super.setUp()
        savedProvider = GuardInstaller.settingsProvider
    }

    override func tearDown() {
        GuardInstaller.settingsProvider = savedProvider
        GuardInstaller.refreshScripts()
        super.tearDown()
    }

    private func guardScripts(_ tab: Tab) -> [WKUserScript] {
        tab.webView.configuration.userContentController.userScripts.filter { $0.source.hasPrefix(Scriptlets.marker) }
    }

    func testConfigIsEmbeddedInScripts() {
        let config = Scriptlets.Config(enabled: true, disabledHosts: ["b.example", "a.example"])
        let page = Scriptlets.pageSource(config)
        let isolated = Scriptlets.isolatedSource(config)
        XCTAssertTrue(page.hasPrefix(Scriptlets.marker))
        XCTAssertTrue(page.contains(#""disabled":["a.example","b.example"]"#))
        XCTAssertTrue(page.contains("kentikPopup"))
        XCTAssertTrue(isolated.contains("kentikGuard"))
        XCTAssertTrue(isolated.contains("accounts.google.com"))
    }

    func testFactoryInstallsGuardIntoAllFrames() {
        let tab = Tab(isIncognito: false)
        let configuration = tab.webView.configuration
        XCTAssertFalse(configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        let scripts = guardScripts(tab)
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts.allSatisfy { !$0.isForMainFrameOnly && $0.injectionTime == .atDocumentStart })
        tab.tearDown()
    }

    func testRefreshRebuildsScriptsAndKeepsForeignOnes() {
        let tab = Tab(isIncognito: true)
        let controller = tab.webView.configuration.userContentController
        let foreign = WKUserScript(source: "/* другой модуль */", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        controller.addUserScript(foreign)

        GuardInstaller.settingsProvider = { _ in Scriptlets.Config(enabled: true, disabledHosts: ["serial.example"]) }
        GuardInstaller.refreshScripts()

        let scripts = guardScripts(tab)
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts.allSatisfy { $0.source.contains("serial.example") })
        XCTAssertTrue(controller.userScripts.contains { $0 === foreign })
        tab.tearDown()
    }

    /// Скриплет в настоящем WebKit: window.open отдаёт пустышку и сообщает о блокировке;
    /// на сайте-исключении скриплета нет.
    func testWindowOpenIsDefusedInWebKit() async throws {
        let tab = Tab(isIncognito: true)
        try await load(tab, host: "kentik.test")
        let result = try await tab.webView.evaluateJavaScript(
            "(function(){ var w = window.open('https://ads.example/pop'); return w === null ? 'null' : (w.closed === false ? 'fake' : 'real'); })()"
        ) as? String
        XCTAssertEqual(result, "fake")
        let trapped = try await tab.webView.evaluateJavaScript(
            "Object.getOwnPropertyDescriptor(window, 'aclib') !== undefined"
        ) as? Bool
        XCTAssertEqual(trapped, true, "ловушка для загрузчика попандеров стоит")
        try await waitUntil { tab.blockedPopups >= 1 }
        XCTAssertEqual(tab.blockedPopups, 1)
        tab.tearDown()
    }

    func testScriptletIsOffOnDisabledSite() async throws {
        GuardInstaller.settingsProvider = { _ in Scriptlets.Config(enabled: true, disabledHosts: ["kentik.test"]) }
        let tab = Tab(isIncognito: true)
        try await load(tab, host: "kentik.test")
        let untouched = try await tab.webView.evaluateJavaScript(
            "Object.getOwnPropertyDescriptor(window, 'aclib') === undefined"
        ) as? Bool
        XCTAssertEqual(untouched, true, "на сайте-исключении скриплет ничего не трогает")
        tab.tearDown()
    }

    /// В списке исключений — регистрируемые домены: выключение на kentik.test выключает
    /// скриплет и на m.kentik.test.
    func testScriptletIsOffOnSubdomainOfDisabledSite() async throws {
        GuardInstaller.settingsProvider = { _ in Scriptlets.Config(enabled: true, disabledHosts: ["kentik.test"]) }
        let tab = Tab(isIncognito: true)
        try await load(tab, host: "m.kentik.test")
        let untouched = try await tab.webView.evaluateJavaScript(
            "Object.getOwnPropertyDescriptor(window, 'aclib') === undefined"
        ) as? Bool
        XCTAssertEqual(untouched, true, "на поддомене сайта-исключения скриплет ничего не трогает")
        tab.tearDown()

        let other = Tab(isIncognito: true)
        try await load(other, host: "notkentik.test")
        let trapped = try await other.webView.evaluateJavaScript(
            "Object.getOwnPropertyDescriptor(window, 'aclib') !== undefined"
        ) as? Bool
        XCTAssertEqual(trapped, true, "на другом сайте скриплет работает")
        other.tearDown()
    }

    // MARK: - Вспомогательное

    private func load(_ tab: Tab, host: String) async throws {
        let html = "<!doctype html><html><head><title>t</title></head><body><p>Kentik</p></body></html>"
        tab.webView.loadHTMLString(html, baseURL: URL(string: "https://\(host)/"))
        try await waitUntil { !tab.webView.isLoading && tab.webView.title == "t" }
    }

    private func waitUntil(timeout: TimeInterval = 15, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("не дождались условия")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

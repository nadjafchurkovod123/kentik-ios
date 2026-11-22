import XCTest

/// Живые проверки на сайтах с сериалами и YouTube (нужен интернет; CI запускает их отдельным
/// шагом, который сборку не валит — сайты меняются и бывают недоступны). Каждый прогон пишет
/// состояние приложения и фреймов (DiagProbe) в /tmp/kentik-diag/<имя> — артефакт diag,
/// снимки — вложениями. Режимы: ON — 1.0.2 как есть; AUTOLAYOUT — веб-вью на Auto Layout, как
/// в 1.0.1; OFF — щит выключен; NOADGUARD — без скриплетов AdGuard.
final class SeriesDiagUITests: XCTestCase {

    static let fixtures = "http://127.0.0.1:8765"

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    enum Mode: String {
        case on = "ON", off = "OFF", autoLayout = "AUTOLAYOUT", noAdGuard = "NOADGUARD"

        var arguments: [String] {
            switch self {
            case .on: return []
            case .off: return ["-shield.enabled", "NO"]
            case .autoLayout: return ["-KentikWebViewAutoLayout"]
            case .noAdGuard: return ["-KentikNoAdGuard"]
            }
        }
    }

    // MARK: - Фикстура: 1.0.2 против 1.0.1 (два входа на весь экран подряд)

    @MainActor
    func testFixtureIframePlayerFullscreen() {
        for (mode, src) in [(Mode.on, "hls"), (.autoLayout, "hls"), (.off, "hls")] {
            fixtureRun(mode: mode, src: src)
        }
    }

    @MainActor
    private func fixtureRun(mode: Mode, src: String) {
        let name = "fixture-\(src)-\(mode.rawValue)"
        let diag = Diag(name)
        let app = XCUIApplication()
        app.launchArguments = ["-KentikUITest", "-KentikStartURL", "\(Self.fixtures)/media/host.html?src=\(src)"] + mode.arguments
        app.launchEnvironment = diag.environment
        app.launch()
        _ = app.staticTexts["pageTitle"].waitForExistence(timeout: 300)
        _ = waitTitle(app, contains: "Kentik Series", timeout: 60)
        sleep(2)
        attachScreen("\(name)-1-page")
        let play = app.webViews.buttons["Пуск"]
        if play.waitForExistence(timeout: 15) { play.tap() }
        _ = waitTitle(app, contains: "идёт", timeout: 20)
        sleep(2)
        for round in 1...2 {
            let fs = app.webViews.buttons["На весь экран"]
            if fs.exists && fs.isHittable { fs.tap() } else {
                diag.eval("window.kentikPlayer && kentikPlayer.fullscreen(); 'ok'", frames: "url:player.html")
            }
            sleep(4)
            let a = attachScreen("\(name)-\(round)-fullscreen-a")
            sleep(2)
            let b = attachScreen("\(name)-\(round)-fullscreen-b")
            diag.snapshotState("\(round)-fullscreen")
            let s = Pixels.stats(a)
            diag.note("\(round)-fullscreen-pixels", ["lit": s.lit, "colorful": s.colorful, "diff": Pixels.difference(a, b),
                                                     "fullscreen": diag.state()["fullscreen"] ?? "?"])
            diag.eval("(document.exitFullscreen||document.webkitExitFullscreen).call(document); 'ok'", frames: "url:player.html")
            sleep(3)
            let after = attachScreen("\(name)-\(round)-after")
            diag.snapshotState("\(round)-after")
            diag.note("\(round)-after-pixels", ["lit": Pixels.stats(after).lit, "webViewFrame": diag.state()["webViewFrame"] ?? [Int]()])
        }
        app.terminate()
    }

    // MARK: - Живые сайты с сериалами

    /// kinogo.online — сайт из жалобы. С адресов GitHub Actions (США) Cloudflare показывает
    /// проверку «Just a moment…»: её мы не проходим (это защита от ботов) — снимок для отчёта.
    @MainActor
    func testLiveKinogoOnline() {
        liveSeries(site: "kinogo-online", start: "https://kinogo.online/", query: "менталист", mode: .on)
    }

    /// Зеркало Киного с теми же балансерами (Alloha, HDVB/Collaps во фрейме).
    @MainActor
    func testLiveKinogoGG() {
        for mode in [Mode.on, .off] {
            liveSeries(site: "kinogo-gg", start: "https://kinogo.gg/4816-mentalistka-1-sezon.html", query: nil, mode: mode)
        }
    }

    @MainActor
    func testLiveKinokrad() {
        liveSeries(site: "kinokrad", start: "https://kinokrad.cc/478966-mentalistka.html", query: nil, mode: .on)
    }

    @MainActor
    func testLiveLordserial() {
        liveSeries(site: "lordserial", start: "https://lordserial.run/zarubezhnye-serialy/202-mentalist-v1.html", query: nil, mode: .on)
    }

    // MARK: - YouTube

    @MainActor
    func testLiveYouTube() {
        for (video, mode) in [("dQw4w9WgXcQ", Mode.noAdGuard), ("dQw4w9WgXcQ", .on), ("kJQP7kiw5Fk", .noAdGuard), ("kJQP7kiw5Fk", .on)] {
            let name = "youtube-\(video)-\(mode.rawValue)"
            let diag = Diag(name)
            let app = XCUIApplication()
            app.launchArguments = ["-KentikUITest", "-KentikStartURL", "https://m.youtube.com/watch?v=\(video)"] + mode.arguments
            app.launchEnvironment = diag.environment
            app.launch()
            waitLoaded(app, diag, timeout: 300)
            sleep(6)
            attachScreen("\(name)-1-watch")
            // Пуск без звука (как пальцем — у eval WebKit есть жест пользователя).
            diag.eval("(function(){var v=__kentikDeepAll('video')[0]; if(!v) return 'нет видео'; v.muted=true; v.play(); return 'play';})()",
                      frames: "main", world: "diag")
            var samples: [String] = []
            for i in 0..<4 {
                sleep(5)
                samples.append(diag.evalString(Self.youTubeProbe))
                if i == 1 { attachScreen("\(name)-2-playing") }
            }
            attachScreen("\(name)-3-later")
            diag.snapshotState("2-watch")
            let state = diag.state()
            let adStatusBlocked = ((state["ruleHits"] as? [[String: Any]]) ?? []).contains {
                ($0["blocked"] as? Bool) == true && (($0["url"] as? String) ?? "").contains("ad_status.js")
            }
            diag.note("youtube-ads", ["samples": samples, "adStatusBlocked": adStatusBlocked,
                                      "tabs": state["tabs"] ?? 0, "blockedPopups": state["blockedPopups"] ?? 0])
            XCTContext.runActivity(named: "\(name): ad_status заблокирован=\(adStatusBlocked); \(samples.last ?? "")") { _ in }
            app.terminate()
        }
    }

    /// Ответ плеера и признаки рекламы на странице YouTube.
    static let youTubeProbe = """
    (function(){
      function keys(o){ return o ? ['adPlacements','playerAds','adSlots'].filter(function(k){ return k in o && o[k] !== undefined; }) : []; }
      var r = window.ytInitialPlayerResponse;
      var p = document.querySelector('#movie_player');
      var live = null; try { live = p && p.getPlayerResponse ? p.getPlayerResponse() : null; } catch (e) {}
      var v = document.querySelector('video');
      var adUI = !!document.querySelector('.ad-showing, .ad-interrupting, .ytp-ad-player-overlay, .ytp-ad-module *, ytm-promoted-sparkles-web-renderer, .ytm-promoted-video-renderer, ad-badge-view-model');
      // Скриптлет json-prune AdGuard стоит в странице: ответ плеера теряет рекламные поля.
      var pruned = keys((JSON.parse('{"playerResponse":{"adPlacements":[1],"playerAds":[1],"adSlots":[1],"videoDetails":{}}}') || {}).playerResponse);
      return JSON.stringify({ initial: keys(r), live: keys(live), adUI: adUI, gas: window.google_ad_status === 1, prunedLeft: pruned,
        playing: !!(v && !v.paused && v.currentTime > 0), t: v ? Math.round(v.currentTime) : -1,
        duration: v ? Math.round(v.duration || 0) : -1, title: document.title.slice(0, 60) });
    })()
    """

    // MARK: - Прогон живого сайта

    @MainActor
    private func liveSeries(site: String, start: String, query: String?, mode: Mode) {
        let name = "\(site)-\(mode.rawValue)"
        let diag = Diag(name)
        let app = XCUIApplication()
        app.launchArguments = ["-KentikUITest", "-KentikStartURL", start] + mode.arguments
        app.launchEnvironment = diag.environment
        app.launch()
        waitLoaded(app, diag, timeout: 300)
        sleep(6)
        attachScreen("\(name)-1-start")
        diag.snapshotState("1-start")

        if let query {
            var link = findLink(diag, query)
            if link.isEmpty, let host = URL(string: start)?.host {
                let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                diag.send(["op": "load", "url": "https://\(host)/index.php?do=search&subaction=search&story=\(q)"])
                sleep(3)
                waitLoaded(app, diag, timeout: 90)
                sleep(3)
                attachScreen("\(name)-2-search")
                link = findLink(diag, query)
            }
            diag.note("2-link", ["link": link, "title": diag.state()["title"] ?? ""])
            guard !link.isEmpty else {
                XCTContext.runActivity(named: "\(name): страница сериала не найдена (заголовок «\(diag.state()["title"] ?? "")»)") { _ in }
                app.terminate()
                return
            }
            diag.send(["op": "load", "url": link])
            sleep(3)
            waitLoaded(app, diag, timeout: 90)
            sleep(6)
        }
        attachScreen("\(name)-3-series")
        diag.snapshotState("3-series")

        // Вкладки плееров («Плеер 1», «Alloha»…): первая — касанием, как пальцем.
        let tab = diag.evalString(Self.findPlayerTabJS)
        if let point = screenPoint(app, tab) {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
            sleep(6)
            attachScreen("\(name)-4-player-tab")
        }
        // Плеер — в середину экрана; касание по центру, как пальцем (ленивые iframe грузятся по касанию).
        for attempt in 1...3 where !diag.isVideoPlaying() {
            let player = diag.evalString(Self.findPlayerJS)
            if attempt == 1 { diag.note("4-player", ["player": player]) }
            sleep(2)
            if let point = screenPoint(app, player) {
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
            }
            sleep(8)
            attachScreen("\(name)-5-tap\(attempt)")
            diag.snapshotState("5-tap\(attempt)")
        }
        if !diag.isVideoPlaying() {
            diag.eval("(function(){var v=__kentikDeepAll('video'); if(!v.length) return 'нет видео'; v.forEach(function(x){x.muted=true; x.play();}); return 'play';})()",
                      frames: "all", world: "diag")
            sleep(10)
            attachScreen("\(name)-6-forced-play")
        }
        diag.snapshotState("6-play")
        let playing = diag.isVideoPlaying()

        // На весь экран — контейнер плеера (как кнопка плееров PlayerJS).
        diag.eval("""
        (function(){var vs=__kentikDeepAll('video').filter(function(v){return !v.paused||v.readyState>1;}); var v=vs[0]||__kentikDeepAll('video')[0];
          if(!v) return 'нет видео';
          var el=v.closest('[id*=player],[class*=player],[id*=Player],[class*=Player]')||v.parentElement;
          var r=el.requestFullscreen||el.webkitRequestFullscreen; if(r){ r.call(el); return 'fs '+el.tagName; }
          v.webkitEnterFullscreen(); return 'native';})()
        """, frames: "video", world: "diag")
        sleep(5)
        let a = attachScreen("\(name)-7-fullscreen-a")
        sleep(2)
        let b = attachScreen("\(name)-8-fullscreen-b")
        diag.snapshotState("7-fullscreen")
        let s = Pixels.stats(a)
        let fsState = diag.state()["fullscreen"] ?? "?"
        diag.eval("(document.exitFullscreen||document.webkitExitFullscreen).call(document); var v=__kentikDeepAll('video')[0]; v&&v.webkitExitFullscreen&&v.webkitDisplayingFullscreen&&v.webkitExitFullscreen(); 'ok'",
                  frames: "video", world: "diag")
        sleep(3)
        let after = attachScreen("\(name)-9-after-fullscreen")
        diag.snapshotState("9-after")
        let state = diag.state()
        let summary: [String: Any] = [
            "playing": playing, "fullscreen": fsState, "fsLit": s.lit, "fsColorful": s.colorful,
            "fsDiff": Pixels.difference(a, b), "afterLit": Pixels.stats(after).lit,
            "webViewFrameAfter": state["webViewFrame"] ?? [Int](), "tabs": state["tabs"] ?? 0,
            "blockedPopups": state["blockedPopups"] ?? 0, "blockedRedirects": state["blockedRedirects"] ?? 0,
            "url": state["url"] ?? "", "title": state["title"] ?? "",
        ]
        diag.note("summary", summary)
        XCTContext.runActivity(named: "\(name): \(summary)") { _ in }
        app.terminate()
    }

    /// Первая видимая вкладка переключателя плееров (если есть).
    static let findPlayerTabJS = """
    (function(){
      var c=[].slice.call(document.querySelectorAll('.tabs li, .js-player-tabs li, .player-tabs li, [data-tab], .tabs__item, .tabs-b li'))
        .filter(function(el){var r=el.getBoundingClientRect(); return r.width>20&&r.height>15&&getComputedStyle(el).visibility!=='hidden';});
      if(!c.length) return '';
      var el=c[0]; el.scrollIntoView({block:'center'});
      var r=el.getBoundingClientRect();
      return JSON.stringify({tag:el.tagName,text:(el.textContent||'').trim().slice(0,40),x:r.left+r.width/2,y:r.top+r.height/2,vw:innerWidth});
    })()
    """

    /// Самый крупный плеер на странице (iframe/video или блок «player»): прокрутить в середину
    /// и вернуть его центр в CSS-пикселях.
    static let findPlayerJS = """
    (function(){
      var c=[].slice.call(document.querySelectorAll('iframe, video, video-player, [id*=player], [class*=player], [class*=Player], [id*=Player]'))
        .map(function(el){var r=el.getBoundingClientRect(); return {el:el,a:r.width*r.height,r:r};})
        .filter(function(x){return x.r.width>=200&&x.r.height>=110&&getComputedStyle(x.el).display!=='none'&&!/youtube/.test(x.el.src||'');});
      c.sort(function(a,b){var pa=/IFRAME|VIDEO/.test(a.el.tagName)?1:0, pb=/IFRAME|VIDEO/.test(b.el.tagName)?1:0; return pb-pa||b.a-a.a;});
      if(!c.length) return '';
      var el=c[0].el; el.scrollIntoView({block:'center'});
      var r=el.getBoundingClientRect();
      return JSON.stringify({tag:el.tagName,id:el.id,cls:String(el.className).slice(0,60),src:String(el.src||el.getAttribute('data-src')||'').slice(0,160),
        x:r.left+r.width/2,y:r.top+r.height/2,w:r.width,h:r.height,vw:innerWidth});
    })()
    """

    @MainActor
    private func findLink(_ diag: Diag, _ query: String) -> String {
        diag.evalString("""
        (function(q){var re=new RegExp(q,'i');
          var a=[].slice.call(document.querySelectorAll('a[href]')).filter(function(x){
            return re.test((x.textContent||'')+' '+(x.title||'')) && x.href.indexOf(location.hostname)>=0 && /\\.html|serial|film|\\/\\d+/.test(x.href);});
          return a.length ? a[0].href : '';})(\(Self.jsString(query)))
        """)
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// Центр плеера (CSS-пиксели страницы) → точка на экране.
    @MainActor
    private func screenPoint(_ app: XCUIApplication, _ json: String) -> CGPoint? {
        guard let data = json.data(using: .utf8),
              let p = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let x = p["x"] as? Double, let y = p["y"] as? Double else { return nil }
        let web = app.webViews.firstMatch
        guard web.exists else { return nil }
        let frame = web.frame
        let vw = (p["vw"] as? Double) ?? Double(frame.width)
        let scale = Double(frame.width) / max(vw, 1)
        let px = Double(frame.minX) + x * scale
        let py = Double(frame.minY) + y * scale
        guard py > Double(frame.minY), py < Double(frame.maxY) else { return nil }
        return CGPoint(x: px, y: py)
    }

    @MainActor
    private func waitLoaded(_ app: XCUIApplication, _ diag: Diag, timeout: TimeInterval) {
        _ = app.staticTexts["pageTitle"].waitForExistence(timeout: timeout)
        _ = diag.waitFor(min(timeout, 90), poll: 2) {
            let s = diag.state()
            return (s["loading"] as? Bool) == false && !((s["url"] as? String) ?? "").isEmpty
        }
    }

    @MainActor
    private func waitTitle(_ app: XCUIApplication, contains text: String, timeout: TimeInterval) -> Bool {
        let title = app.staticTexts["pageTitle"]
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: title)], timeout: timeout) == .completed
    }
}

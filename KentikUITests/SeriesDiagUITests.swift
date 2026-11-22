import XCTest

/// Диагностика «чёрного видео» на сайтах с сериалами (нужен интернет для живых сайтов).
/// Каждый прогон пишет состояние приложения и фреймов (DiagProbe) в /tmp/kentik-diag/<имя>,
/// снимки — вложениями. Режимы: ON — как в 1.0.1, OFF — щит выключен, NOGUARD — без
/// скриплетов защиты, NOBLOCKER — без списков блокировщика, AUTORESIZE — веб-вью на
/// autoresizing вместо Auto Layout.
final class SeriesDiagUITests: XCTestCase {

    static let fixtures = "http://127.0.0.1:8765"

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    enum Mode: String {
        case on = "ON", off = "OFF", noGuard = "NOGUARD", noBlocker = "NOBLOCKER", autoresize = "AUTORESIZE"

        var arguments: [String] {
            switch self {
            case .on: return []
            case .off: return ["-shield.enabled", "NO"]
            case .noGuard: return ["-KentikNoGuard"]
            case .noBlocker: return ["-KentikNoBlocker"]
            case .autoresize: return ["-KentikWebViewAutoresizing"]
            }
        }
    }

    // MARK: - Фикстура: плеер с другого сайта во фрейме

    @MainActor
    func testFixtureIframePlayerFullscreen() {
        for (mode, src) in [(Mode.on, "hls"), (.off, "hls"), (.autoresize, "hls"), (.on, "mp4")] {
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
        let title = app.staticTexts["pageTitle"]
        _ = title.waitForExistence(timeout: 300)
        _ = waitTitle(app, contains: "Kentik Series", timeout: 60)
        sleep(2)
        attachScreen("\(name)-1-page")

        let play = app.webViews.buttons["Пуск"]
        if play.waitForExistence(timeout: 15) { play.tap() } else { XCTFail("\(name): нет кнопки «Пуск» в плеере") }
        let playing = waitTitle(app, contains: "идёт", timeout: 20)
        sleep(2)
        attachScreen("\(name)-2-playing")
        diag.snapshotState("2-playing")
        XCTAssertTrue(playing, "\(name): видео во фрейме не пошло (\(title.label))")

        let fs = app.webViews.buttons["На весь экран"]
        if fs.exists { fs.tap() } else { diag.eval("window.kentikPlayer && kentikPlayer.fullscreen(); 'ok'", frames: "url:player.html") }
        sleep(4)
        let a = attachScreen("\(name)-3-fullscreen-a")
        sleep(2)
        let b = attachScreen("\(name)-4-fullscreen-b")
        diag.snapshotState("3-fullscreen")
        let sa = Pixels.stats(a), sb = Pixels.stats(b)
        let diff = Pixels.difference(a, b)
        diag.note("3-fullscreen-pixels", ["litA": sa.lit, "colorfulA": sa.colorful, "litB": sb.lit, "colorfulB": sb.colorful, "diff": diff])
        XCTContext.runActivity(named: "\(name): на весь экран светлых \(sa.lit), цветных \(sa.colorful), разница \(diff)") { _ in }

        diag.eval("(document.exitFullscreen||document.webkitExitFullscreen).call(document); 'ok'", frames: "url:player.html")
        sleep(3)
        attachScreen("\(name)-5-after-fullscreen")
        diag.snapshotState("5-after-fullscreen")

        let native = app.webViews.buttons["Системный"]
        if native.exists {
            native.tap()
            sleep(4)
            let n = attachScreen("\(name)-6-native-fullscreen")
            let ns = Pixels.stats(n)
            diag.snapshotState("6-native")
            diag.note("6-native-pixels", ["lit": ns.lit, "colorful": ns.colorful])
            diag.eval("var v=document.querySelector('video'); v.webkitExitFullscreen && v.webkitExitFullscreen(); 'ok'", frames: "url:player.html")
            sleep(3)
            attachScreen("\(name)-7-after-native")
            diag.snapshotState("7-after-native")
        }
        app.terminate()
    }

    // MARK: - Живые сайты

    @MainActor
    func testLiveKinogoOnline() {
        for mode in [Mode.on, .off, .noGuard, .noBlocker] {
            liveSeries(site: "kinogo-online", start: "https://kinogo.online/", query: "менталист", mode: mode)
        }
    }

    @MainActor
    func testLiveKinogoBiz() {
        for mode in [Mode.on, .off] {
            liveSeries(site: "kinogo-biz", start: "https://kinogo.biz/111930--titany.html", query: nil, mode: mode)
        }
    }

    @MainActor
    func testLiveLordserial() {
        for mode in [Mode.on, .off] {
            liveSeries(site: "lordserial", start: "https://lordserial.run/", query: "менталист", mode: mode)
        }
    }

    @MainActor
    func testLiveYouTubeBaseline() {
        for mode in [Mode.on, .off] {
            let name = "youtube-\(mode.rawValue)"
            let diag = Diag(name)
            let app = XCUIApplication()
            app.launchArguments = ["-KentikUITest", "-KentikStartURL", "https://m.youtube.com/watch?v=jNQXAC9IVRw"] + mode.arguments
            app.launchEnvironment = diag.environment
            app.launch()
            waitLoaded(app, diag, timeout: 300)
            sleep(8)
            attachScreen("\(name)-1-watch")
            let info = diag.evalString("""
            (function(){
              var r = window.ytInitialPlayerResponse || {};
              var p = document.querySelector('#movie_player');
              var live = null; try { live = p && p.getPlayerResponse ? p.getPlayerResponse() : null; } catch (e) {}
              function keys(o){ return o ? ['adPlacements','playerAds','adSlots','adBreakHeartbeatParams'].filter(function(k){ return k in o; }) : []; }
              return JSON.stringify({ initial: keys(r), live: keys(live), adShowing: !!document.querySelector('.ad-showing, .ad-interrupting'),
                gas: window.google_ad_status, flags: !!(window.yt && yt.config_ && yt.config_.EXPERIMENT_FLAGS), title: document.title });
            })()
            """)
            diag.note("1-youtube-ads", info)
            XCTContext.runActivity(named: "\(name): \(info)") { _ in }
            diag.snapshotState("1-watch")
            app.terminate()
        }
    }

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
        sleep(5)
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
            if link.isEmpty { link = findLink(diag, "сезон") }
            diag.note("2-link", ["link": link])
            guard !link.isEmpty else {
                XCTContext.runActivity(named: "\(name): не нашли страницу сериала") { _ in }
                diag.snapshotState("2-no-link")
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

        // Плеер — в середину экрана, касание по центру (как пальцем).
        let player = diag.evalString(Self.findPlayerJS)
        diag.note("4-player", ["player": player])
        sleep(2)
        attachScreen("\(name)-4-player")
        if let point = screenPoint(app, player) {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
            sleep(8)
            attachScreen("\(name)-5-tap1")
            diag.snapshotState("5-tap1")
            if !diag.isVideoPlaying() {
                // Плееры часто ждут второго касания по своей кнопке «пуск».
                let again = diag.evalString(Self.findPlayerJS)
                if let p2 = screenPoint(app, again) {
                    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p2.x, dy: p2.y)).tap()
                }
                sleep(8)
                attachScreen("\(name)-6-tap2")
                diag.snapshotState("6-tap2")
            }
        }
        if !diag.isVideoPlaying() {
            diag.eval("(function(){var v=document.querySelector('video'); if(!v) return 'нет видео'; v.muted=true; var p=v.play(); return 'play';})()", frames: "video")
            sleep(8)
            attachScreen("\(name)-7-forced-play")
            diag.snapshotState("7-forced-play")
        }
        let playing = diag.isVideoPlaying()
        XCTContext.runActivity(named: "\(name): видео идёт — \(playing)") { _ in }

        // На весь экран — контейнер плеера (как кнопка плееров PlayerJS).
        diag.eval("""
        (function(){var v=document.querySelector('video'); if(!v) return 'нет видео';
          var el=v.closest('[id*=player],[class*=player],[id*=Player],[class*=Player]')||v.parentElement;
          var r=el.requestFullscreen||el.webkitRequestFullscreen; if(r){ var p=r.call(el); if(p&&p.catch)p.catch(function(e){document.title='fs-error '+e.name;}); return 'fs '+el.tagName; }
          v.webkitEnterFullscreen(); return 'native';})()
        """, frames: "video")
        sleep(5)
        let a = attachScreen("\(name)-8-fullscreen-a")
        sleep(2)
        let b = attachScreen("\(name)-9-fullscreen-b")
        diag.snapshotState("8-fullscreen")
        let sa = Pixels.stats(a)
        diag.note("8-fullscreen-pixels", ["lit": sa.lit, "colorful": sa.colorful, "diff": Pixels.difference(a, b)])
        diag.eval("(document.exitFullscreen||document.webkitExitFullscreen).call(document); 'ok'", frames: "video")
        sleep(3)
        attachScreen("\(name)-10-after-fullscreen")
        diag.snapshotState("10-after-fullscreen")
        app.terminate()
    }

    /// Самый крупный плеер на странице (iframe/video или блок «player»): прокрутить в середину
    /// и вернуть его центр в CSS-пикселях.
    static let findPlayerJS = """
    (function(){
      var c=[].slice.call(document.querySelectorAll('iframe, video, [id*=player], [class*=player], [class*=Player], [id*=Player]'))
        .map(function(el){var r=el.getBoundingClientRect(); return {el:el,a:r.width*r.height,r:r};})
        .filter(function(x){return x.r.width>=200&&x.r.height>=110&&getComputedStyle(x.el).display!=='none';});
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

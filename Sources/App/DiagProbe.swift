import UIKit
import WebKit

/// Диагностика для UI-тестов на настоящих сайтах (только DEBUG, включается переменной
/// окружения KENTIK_DIAG_DIR — папкой на диске Mac, симулятор пишет туда напрямую).
///
///  * Во все фреймы ставится скрипт в отдельном мире «KentikDiag»: раз в 1,5 с он сообщает
///    адрес фрейма, видео (идёт ли, время, размер кадра, ошибки), iframe (размер, видимость,
///    атрибуты allow/allowfullscreen), элементы, спрятанные защитой Kentik, полноэкранный
///    элемент и ошибки JavaScript.
///  * Срабатывания правил блокировщика (какой адрес снят каким списком) — через делегат
///    навигации WebKit (_webView:contentRuleListWithIdentifier:performedAction:forURL:).
///  * Решения защиты (окна, переходы, слои) — DiagProbe.event(...).
///  * Состояние приложения пишется в state.json; команды теста — файлы cmd-<n>.json
///    ({"op": "eval", "js": "...", "frames": "main|all|video|url:<часть адреса>"} и др.),
///    ответы — res-<n>.json.
/// В Release этого файла по сути нет: всё под #if DEBUG.
@MainActor
enum DiagProbe {
#if DEBUG
    static let world = WKContentWorld.world(name: "KentikDiag")
    static let handlerName = "kentikDiag"

    static var directory: URL? = {
        guard let path = ProcessInfo.processInfo.environment["KENTIK_DIAG_DIR"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var isEnabled: Bool { directory != nil }

    static weak var tabManager: TabManager?

    private struct FrameReport {
        var info: WKFrameInfo
        weak var webView: WKWebView?
        var body: [String: Any]
        var at: Date
    }

    private static var frames: [String: FrameReport] = [:]
    private static var events: [[String: Any]] = []
    private static var ruleHits: [[String: Any]] = []
    private static var timer: Timer?
    private static var processed = Set<Int>()
    private static let handler = DiagHandler()

    static func install(on configuration: WKWebViewConfiguration) {
        guard isEnabled else { return }
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.hasPrefix("/*kentik-diag*/") }) else { return }
        controller.add(handler, contentWorld: world, name: handlerName)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
        startTimer()
    }

    static func event(_ kind: String, _ details: [String: Any] = [:]) {
        guard isEnabled else { return }
        var item = details
        item["kind"] = kind
        item["at"] = Date().timeIntervalSince1970
        events.append(item)
        if events.count > 400 { events.removeFirst(events.count - 400) }
    }

    static func ruleAction(list: String, url: URL?, blocked: Bool, page: URL?) {
        guard isEnabled else { return }
        ruleHits.append(["list": list, "url": String((url?.absoluteString ?? "").prefix(300)),
                         "blocked": blocked, "page": page?.host ?? "", "at": Date().timeIntervalSince1970])
        if ruleHits.count > 800 { ruleHits.removeFirst(ruleHits.count - 800) }
    }

    fileprivate static func receive(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let info = message.frameInfo
        let url = body["url"] as? String ?? info.request.url?.absoluteString ?? "?"
        let key = (info.isMainFrame ? "main " : "frame ") + url
        frames[key] = FrameReport(info: info, webView: message.webView, body: body, at: Date())
    }

    // MARK: - Состояние и команды

    private static func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    private static var lastStateWrite = Date.distantPast

    private static func tick() {
        guard let dir = directory else { return }
        if Date().timeIntervalSince(lastStateWrite) > 1 {
            lastStateWrite = Date()
            write(stateObject(), to: dir.appendingPathComponent("state.json"))
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let commands = names.compactMap { name -> Int? in
            guard name.hasPrefix("cmd-"), name.hasSuffix(".json") else { return nil }
            return Int(name.dropFirst(4).dropLast(5))
        }.filter { !processed.contains($0) }.sorted()
        for id in commands {
            processed.insert(id)
            let file = dir.appendingPathComponent("cmd-\(id).json")
            guard let data = try? Data(contentsOf: file),
                  let command = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            run(command) { result in
                write(result, to: dir.appendingPathComponent("res-\(id).json"))
            }
        }
    }

    private static func selectedTab() -> Tab? { tabManager?.selectedTab }

    static func stateObject() -> [String: Any] {
        let now = Date()
        frames = frames.filter { now.timeIntervalSince($0.value.at) < 8 && $0.value.webView != nil }
        let tab = selectedTab()
        var state: [String: Any] = ["at": now.timeIntervalSince1970]
        if let tab {
            let webView: WKWebView = tab.webView
            state["url"] = webView.url?.absoluteString ?? ""
            state["title"] = tab.title
            state["incognito"] = tab.isIncognito
            state["loading"] = tab.isLoading
            state["blockedPopups"] = tab.blockedPopups
            state["blockedRedirects"] = tab.blockedRedirects
            state["hiddenByGuard"] = tab.hiddenByGuard
            state["fullscreen"] = fullscreenName(webView)
            state["webViewFrame"] = rectArray(webView.frame)
            state["webViewInWindow"] = webView.window != nil
            state["webViewHidden"] = webView.isHidden
            state["webViewSuperview"] = webView.superview.map { String(describing: type(of: $0)) } ?? "nil"
            state["webViewTAMIC"] = webView.translatesAutoresizingMaskIntoConstraints
            state["mediaPlayback"] = mediaState
            state["frames"] = frames.values.filter { $0.webView === webView }.map { $0.body }
        }
        state["tabs"] = tabManager?.tabs.count ?? 0
        state["incognitoTabs"] = tabManager?.incognitoTabs.count ?? 0
        state["locked"] = IncognitoLock.shared.isLocked
        state["events"] = Array(events.suffix(120))
        state["ruleHits"] = Array(ruleHits.suffix(300))
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        state["windows"] = windows.map { "\(type(of: $0)) level=\($0.windowLevel.rawValue) hidden=\($0.isHidden) key=\($0.isKeyWindow) frame=\(rectArray($0.frame))" }
        state["orientation"] = windows.first?.windowScene?.interfaceOrientation.rawValue ?? 0
        return state
    }

    private static var mediaState = "?"

    private static func fullscreenName(_ webView: WKWebView) -> String {
        if #available(iOS 16.0, *) {
            switch webView.fullscreenState {
            case .notInFullscreen: return "none"
            case .enteringFullscreen: return "entering"
            case .inFullscreen: return "in"
            case .exitingFullscreen: return "exiting"
            @unknown default: return "unknown"
            }
        }
        return "n/a"
    }

    private static func rectArray(_ r: CGRect) -> [Int] {
        [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)]
    }

    private static func run(_ command: [String: Any], completion: @escaping @MainActor ([String: Any]) -> Void) {
        let op = command["op"] as? String ?? ""
        switch op {
        case "state":
            completion(stateObject())
        case "load":
            if let s = command["url"] as? String, let url = URL(string: s), let tab = selectedTab() {
                tab.load(url)
                completion(["ok": true])
            } else {
                completion(["ok": false, "error": "нет вкладки или адреса"])
            }
        case "media":
            guard let webView = selectedTab()?.webView else { return completion(["ok": false]) }
            webView.requestMediaPlaybackState { state in
                MainActor.assumeIsolated {
                    mediaState = "\(state.rawValue)"
                    completion(["ok": true, "state": state.rawValue])
                }
            }
        case "eval":
            evaluate(command, completion: completion)
        default:
            completion(["ok": false, "error": "неизвестная команда \(op)"])
        }
    }

    private static func evaluate(_ command: [String: Any], completion: @escaping @MainActor ([String: Any]) -> Void) {
        guard let webView = selectedTab()?.webView else { return completion(["ok": false, "error": "нет вкладки"]) }
        let js = command["js"] as? String ?? "null"
        let filter = command["frames"] as? String ?? "main"
        let world: WKContentWorld = (command["world"] as? String) == "diag" ? self.world : .page
        let reports = frames.values.filter { $0.webView === webView }
        var targets: [(String, WKFrameInfo?)] = []
        switch filter {
        case "main":
            targets = [("main", nil)]
        case "all":
            targets = reports.map { ($0.body["url"] as? String ?? "?", $0.info) }
        case "video":
            targets = reports.filter { (($0.body["vids"] as? [Any])?.count ?? 0) > 0 }
                .map { ($0.body["url"] as? String ?? "?", $0.info) }
        default:
            let part = filter.hasPrefix("url:") ? String(filter.dropFirst(4)) : filter
            targets = reports.filter { ($0.body["url"] as? String ?? "").contains(part) }
                .map { ($0.body["url"] as? String ?? "?", $0.info) }
        }
        if targets.isEmpty { return completion(["ok": false, "error": "нет фреймов «\(filter)»", "results": []]) }
        let box = Accumulator(left: targets.count)
        for (name, info) in targets {
            webView.evaluateJavaScript(js, in: info, in: world) { result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let value):
                        box.results.append(["frame": name, "value": jsonSafe(value)])
                    case .failure(let error):
                        box.results.append(["frame": name, "error": error.localizedDescription])
                    }
                    box.left -= 1
                    if box.left == 0 { completion(["ok": true, "results": box.results]) }
                }
            }
        }
    }

    private final class Accumulator {
        var results: [[String: Any]] = []
        var left: Int
        init(left: Int) { self.left = left }
    }

    private static func jsonSafe(_ value: Any) -> Any {
        if JSONSerialization.isValidJSONObject(["v": value]) { return value }
        return String(describing: value)
    }

    private static func write(_ object: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private static let script = #"""
    /*kentik-diag*/
    (function () {
      if (window.__kentikDiag) return;
      window.__kentikDiag = 1;
      var H = null;
      try { H = window.webkit.messageHandlers.kentikDiag; } catch (e) {}
      var errors = [], log = [];
      function push(list, s) { list.push(String(s).slice(0, 240)); if (list.length > 25) list.shift(); }
      window.addEventListener('error', function (e) {
        if (e.target && e.target !== window && e.target.tagName) {
          push(errors, 'load error ' + e.target.tagName + ' ' + (e.target.src || e.target.href || ''));
        } else {
          push(errors, (e.message || 'error') + ' @' + (e.filename || '') + ':' + (e.lineno || ''));
        }
      }, true);
      window.addEventListener('unhandledrejection', function (e) { push(errors, 'rejection ' + (e.reason && (e.reason.message || e.reason))); });
      function r(el) { var b = el.getBoundingClientRect(); return [Math.round(b.left), Math.round(b.top), Math.round(b.width), Math.round(b.height)]; }
      function vis(el) { var c = getComputedStyle(el); return c.display + '/' + c.visibility + '/' + c.opacity; }
      function desc(el) { return (el.tagName + (el.id ? '#' + el.id : '') + (typeof el.className === 'string' && el.className ? '.' + el.className.trim().split(/\s+/).slice(0, 3).join('.') : '')).slice(0, 100); }
      // Видео и iframe и в открытых shadow root (плееры-веб-компоненты, например cdnvideohub).
      function deepAll(sel) {
        var out = [], stack = [document];
        while (stack.length && out.length < 50) {
          var root = stack.pop();
          try { out.push.apply(out, [].slice.call(root.querySelectorAll(sel))); } catch (e) {}
          var all = root.querySelectorAll ? root.querySelectorAll('*') : [];
          for (var i = 0; i < all.length && i < 4000; i++) if (all[i].shadowRoot) stack.push(all[i].shadowRoot);
        }
        return out;
      }
      window.__kentikDeepAll = deepAll;
      function report() {
        try {
          var vids = deepAll('video').map(function (v) {
            return { rect: r(v), vis: vis(v), paused: v.paused, t: Math.round(v.currentTime * 10) / 10, rs: v.readyState, ns: v.networkState,
                     w: v.videoWidth, h: v.videoHeight, muted: v.muted, src: String(v.currentSrc || v.src || '').slice(0, 160),
                     err: v.error ? v.error.code : 0, fsNative: !!v.webkitDisplayingFullscreen, mode: v.webkitPresentationMode || '' };
          });
          var ifr = deepAll('iframe').map(function (f) {
            return { rect: r(f), vis: vis(f), src: String(f.src || '').slice(0, 160), dataSrc: String(f.getAttribute('data-src') || '').slice(0, 120),
                     allow: f.getAttribute('allow'), afs: f.hasAttribute('allowfullscreen'), kh: f.getAttribute('data-kentik-hidden') };
          }).filter(function (f) { return f.rect[2] > 0 || f.src; }).slice(0, 15);
          var hidden = [].slice.call(document.querySelectorAll('[data-kentik-hidden]')).slice(0, 15).map(function (el) {
            return el.getAttribute('data-kentik-hidden') + ' ' + desc(el) + ' ' + JSON.stringify(r(el));
          });
          var fs = document.fullscreenElement || document.webkitFullscreenElement;
          var body = document.body;
          var center = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
          var msg = { url: location.href.slice(0, 300), top: window.top === window, title: document.title.slice(0, 120), ready: document.readyState,
                      vids: vids, iframes: ifr, hidden: hidden, fs: fs ? desc(fs) : null, errors: errors.slice(-12), log: log.slice(-20),
                      scripts: document.scripts.length, text: body ? (body.innerText || '').length : 0,
                      bg: body ? getComputedStyle(body).backgroundColor : '', vw: innerWidth, vh: innerHeight, sy: Math.round(scrollY),
                      center: center ? desc(center) : null };
          if (H) H.postMessage(msg);
        } catch (e) { try { H && H.postMessage({ url: location.href, err: String(e) }); } catch (x) {} }
      }
      ['fullscreenchange', 'webkitfullscreenchange', 'fullscreenerror', 'webkitfullscreenerror'].forEach(function (t) {
        document.addEventListener(t, function () { push(log, t + ' ' + ((document.fullscreenElement || document.webkitFullscreenElement) ? 'on' : 'off')); report(); }, true);
      });
      ['play', 'playing', 'pause', 'error', 'stalled', 'waiting', 'loadedmetadata', 'webkitbeginfullscreen', 'webkitendfullscreen',
       'webkitpresentationmodechanged'].forEach(function (t) {
        document.addEventListener(t, function (e) { if (e.target && e.target.tagName === 'VIDEO') { push(log, t + ' t=' + Math.round(e.target.currentTime)); } }, true);
      });
      setInterval(report, 1500);
      document.addEventListener('DOMContentLoaded', report);
      window.addEventListener('load', report);
    })();
    """#
#else
    static var isEnabled: Bool { false }
    static weak var tabManager: TabManager?
    static func install(on configuration: WKWebViewConfiguration) {}
    static func event(_ kind: String, _ details: [String: Any] = [:]) {}
    static func ruleAction(list: String, url: URL?, blocked: Bool, page: URL?) {}
#endif
}

#if DEBUG
@MainActor
private final class DiagHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { DiagProbe.receive(message) }
    }
}
#endif

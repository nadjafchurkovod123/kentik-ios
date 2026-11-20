import UIKit
import WebKit

/// Статья, извлечённая из страницы.
struct ReaderArticle {
    var title: String
    var site: String
    var html: String
    var textLength: Int
    var baseURL: URL?
}

/// Простое извлечение статьи в духе Readability: абзацы дают очки родителю (и половину —
/// «деду»), берём лучший блок, вычищаем скрипты, формы, рекламу и атрибуты.
/// Скрипт выполняется в отдельном мире (.defaultClient), страница не может его подменить.
enum ReaderExtractor {

    static let script = """
    (function() {
      var scores = new Map();
      function add(el, v) { if (el && el !== document.documentElement) scores.set(el, (scores.get(el) || 0) + v); }
      var ps = document.querySelectorAll('p, pre, blockquote');
      for (var i = 0; i < ps.length; i++) {
        var p = ps[i];
        var len = (p.innerText || '').trim().length;
        if (len < 25) continue;
        var commas = (p.innerText.match(/[,،、]/g) || []).length;
        var v = 1 + commas + Math.min(Math.floor(len / 100), 3);
        add(p.parentElement, v);
        if (p.parentElement) add(p.parentElement.parentElement, v / 2);
      }
      var best = null, bestScore = 0;
      scores.forEach(function(v, el) {
        var cls = ((el.className && el.className.baseVal === undefined ? el.className : '') + ' ' + (el.id || '')).toLowerCase();
        if (/comment|footer|sidebar|related|promo|banner|ad-|advert|share|social/.test(cls)) v *= 0.3;
        if (/article|content|post|entry|text|body|story/.test(cls)) v *= 1.3;
        if (el.tagName === 'ARTICLE' || el.tagName === 'MAIN') v *= 1.4;
        if (v > bestScore) { bestScore = v; best = el; }
      });
      if (!best) best = document.querySelector('article, main, [role=main]') || document.body;
      var clone = best.cloneNode(true);
      var junk = 'script,style,noscript,iframe,frame,form,button,input,select,textarea,nav,aside,footer,svg,canvas,video,audio,object,embed,link,meta,[aria-hidden=true],[hidden]';
      clone.querySelectorAll(junk).forEach(function(n) { n.remove(); });
      clone.querySelectorAll('*').forEach(function(n) {
        var cls = ((typeof n.className === 'string' ? n.className : '') + ' ' + (n.id || '')).toLowerCase();
        if (/(^|[\\s_-])(ad|ads|advert|banner|promo|share|social|related|comment)s?($|[\\s_-])/.test(cls)) { n.remove(); return; }
        if (n.tagName === 'IMG') {
          var lazy = n.getAttribute('data-src') || n.getAttribute('data-lazy-src') || n.getAttribute('data-original');
          if (lazy && !n.getAttribute('src')) n.setAttribute('src', lazy);
        }
        var keep = { href: 1, src: 1, alt: 1, title: 1, colspan: 1, rowspan: 1 };
        Array.prototype.slice.call(n.attributes).forEach(function(a) { if (!keep[a.name]) n.removeAttribute(a.name); });
        if (n.tagName === 'A' && n.getAttribute('href') && /^\\s*javascript:/i.test(n.getAttribute('href'))) n.removeAttribute('href');
        if (n.tagName === 'A' && n.href) n.setAttribute('href', n.href);
        if (n.tagName === 'IMG' && n.src) n.setAttribute('src', n.src);
      });
      var h1 = document.querySelector('h1');
      var title = (h1 && h1.innerText.trim()) || document.title || '';
      // Заголовок показываем сами — убираем его повтор из текста статьи.
      var dup = clone.querySelector('h1');
      if (dup && dup.textContent.trim() === title) dup.remove();
      return JSON.stringify({ title: title, site: location.hostname, html: clone.innerHTML, text: (clone.innerText || clone.textContent || '').trim().length });
    })();
    """

    /// Извлечь статью из веб-вью. nil — на странице нет статьи.
    @MainActor
    static func extract(from webView: WKWebView, completion: @escaping @MainActor (ReaderArticle?) -> Void) {
        let baseURL = webView.url
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            MainActor.assumeIsolated {
                guard case .success(let value) = result,
                      let json = value as? String,
                      let data = json.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let html = object["html"] as? String else {
                    completion(nil)
                    return
                }
                let length = object["text"] as? Int ?? 0
                guard length >= 250 else {
                    completion(nil)
                    return
                }
                completion(ReaderArticle(
                    title: object["title"] as? String ?? "",
                    site: object["site"] as? String ?? "",
                    html: html,
                    textLength: length,
                    baseURL: baseURL
                ))
            }
        }
    }

    /// HTML страницы чтения в стиле Kentik.
    static func page(for article: ReaderArticle, fontSize: Int) -> String {
        let title = escape(article.title)
        let site = escape(displayHost(article.site))
        let minutes = max(1, article.textLength / 1200)
        return """
        <!doctype html><html lang="ru"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src * data:; style-src 'unsafe-inline'">
        <style>
          :root { color-scheme: dark; }
          body { margin: 0; padding: 20px 22px 60px; background: #1c1b22; color: #e9e9ef;
                 font: \(fontSize)px/1.62 -apple-system, "Iowan Old Style", Georgia, serif; -webkit-text-size-adjust: 100%; }
          .site { color: #a78bfa; font: 600 13px -apple-system, system-ui; letter-spacing: .02em; text-transform: uppercase; }
          h1.title { font: 700 \(fontSize + 9)px/1.25 -apple-system, system-ui; color: #fbfbfe; margin: 8px 0 6px; }
          .meta { color: #8f8f9d; font: 13px -apple-system, system-ui; margin-bottom: 22px; }
          a { color: #a78bfa; }
          img, figure { max-width: 100%; height: auto; border-radius: 10px; }
          figure { margin: 18px 0; } figcaption { color: #8f8f9d; font-size: .8em; }
          h1, h2, h3, h4 { color: #fbfbfe; line-height: 1.3; font-family: -apple-system, system-ui; }
          blockquote { margin: 16px 0; padding: 4px 16px; border-left: 3px solid #a78bfa; color: #bfbfc9; }
          pre, code { font: 14px ui-monospace, Menlo, monospace; background: #2b2a33; border-radius: 6px; }
          pre { padding: 12px; overflow-x: auto; }
          table { border-collapse: collapse; max-width: 100%; display: block; overflow-x: auto; }
          td, th { border: 1px solid #393842; padding: 6px; }
          hr { border: 0; border-top: 1px solid #393842; }
        </style></head><body>
        <div class="site">\(site)</div>
        <h1 class="title">\(title)</h1>
        <div class="meta">≈ \(minutes) мин чтения</div>
        <article>\(article.html)</article>
        </body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Режим чтения: статья в шторке, без скриптов страницы.
final class ReaderViewController: UIViewController, WKNavigationDelegate {

    private let article: ReaderArticle
    private var fontSize = 19
    private var webView: WKWebView!
    /// Открыть ссылку из статьи в браузере.
    var onOpenLink: ((URL) -> Void)?

    init(article: ReaderArticle) {
        self.article = article
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        view.accessibilityIdentifier = "readerView"
        title = displayHost(article.site)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = Theme.background
        webView.scrollView.backgroundColor = Theme.background
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let smaller = UIBarButtonItem(title: nil, image: UIImage(systemName: "textformat.size.smaller"), primaryAction: UIAction { [weak self] _ in
            self?.changeFont(by: -2)
        }, menu: nil)
        smaller.accessibilityLabel = "Мельче"
        let larger = UIBarButtonItem(title: nil, image: UIImage(systemName: "textformat.size.larger"), primaryAction: UIAction { [weak self] _ in
            self?.changeFont(by: 2)
        }, menu: nil)
        larger.accessibilityLabel = "Крупнее"
        navigationItem.leftBarButtonItems = [smaller, larger]
        let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        done.accessibilityIdentifier = "readerDone"
        navigationItem.rightBarButtonItem = done
        render()
    }

    private func changeFont(by delta: Int) {
        fontSize = min(30, max(13, fontSize + delta))
        render()
    }

    private func render() {
        webView.loadHTMLString(ReaderExtractor.page(for: article, fontSize: fontSize), baseURL: article.baseURL)
    }

    // Ссылки из статьи открываем в браузере, а не внутри шторки.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            decisionHandler(.cancel)
            let callback = onOpenLink
            dismiss(animated: true) { callback?(url) }
            return
        }
        decisionHandler(.allow)
    }
}

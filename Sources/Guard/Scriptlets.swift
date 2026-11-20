import Foundation

/// JS-скриплеты защиты. Ставятся во все фреймы (forMainFrameOnly: false) до загрузки
/// страницы (document-start). Два скрипта:
///
///  * `pageSource` — в мире страницы (ему нужно подменить то, что видит сама страница):
///    window.open (как «nowoif» в uBlock Origin — попандер получает пустышку вместо окна),
///    программные клики по ссылкам и отправку форм в новое окно, ловушки для известных
///    загрузчиков попандеров (как «abort-on-property-read»).
///  * `isolatedSource` — в отдельном мире Kentik (страница его не видит и не может подделать
///    его сообщения): сообщает о касаниях пользователя, гасит невидимые перехватчики касаний
///    над плеером, ловит подмену ссылки в момент клика, прячет стены «отключите AdBlock».
///
/// Всё общее и дешёвое: никакой привязки к сайтам. Настройки (щит включён, сайты-исключения,
/// входы через OAuth) вшиваются в текст скрипта; при их смене GuardInstaller пересобирает
/// скрипты во всех веб-вью.
enum Scriptlets {

    /// Метка в начале каждого скрипта защиты — по ней GuardInstaller находит свои скрипты.
    static let marker = "/*kentik-guard*/"

    /// Настройки, вшиваемые в скрипт.
    struct Config: Equatable {
        var enabled: Bool
        /// Нормализованные хосты (без www.), где щит выключен.
        var disabledHosts: [String]
        var loginHosts: [String] = LoginHosts.domains

        var json: String {
            let object: [String: Any] = [
                "enabled": enabled,
                "disabled": disabledHosts.sorted(),
                "login": loginHosts,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func pageSource(_ config: Config) -> String {
        marker + "(" + pageBody + ")(" + config.json + ");"
    }

    static func isolatedSource(_ config: Config) -> String {
        marker + "(" + isolatedBody + ")(" + config.json + ");"
    }

    // MARK: - Общие функции (вставляются в оба скрипта)

    private static let common = #"""
      var W = window, D = document;
      var now = Date.now.bind(Date);
      var URL_ = W.URL;
      var isTop = false;
      try { isTop = W.top === W; } catch (e) {}
      function norm(h) { h = String(h || '').toLowerCase(); return h.indexOf('www.') === 0 ? h.slice(4) : h; }
      function topHost() {
        try { return W.top.location.hostname; } catch (e) {}
        try {
          var ao = W.location.ancestorOrigins;
          if (ao && ao.length) return new URL_(ao[ao.length - 1]).hostname;
        } catch (e) {}
        return W.location.hostname;
      }
      function hostOf(u) { try { return new URL_(u, D.baseURI).hostname.toLowerCase(); } catch (e) { return ''; } }
      function resolve(u) {
        if (u === undefined || u === null || u === '') return '';
        try { return new URL_(String(u), D.baseURI).href; } catch (e) { return String(u); }
      }
      function matches(host, list) {
        host = String(host || '').toLowerCase();
        for (var i = 0; i < list.length; i++) {
          var d = list[i];
          if (host === d || (host.length > d.length && host.slice(-d.length - 1) === '.' + d)) return true;
        }
        return false;
      }
      function isLogin(u) {
        var h = hostOf(u);
        if (/^(passport|oauth|sso|id)\.yandex\./.test(h)) return true;
        return matches(h, cfg.login);
      }
      function linkHref(n) {
        var href = n.href;
        if (href && typeof href === 'object' && 'baseVal' in href) href = resolve(href.baseVal);
        return href ? String(href) : '';
      }
      function anchorFrom(e) {
        var path = e.composedPath ? e.composedPath() : [];
        for (var i = 0; i < path.length; i++) {
          var n = path[i];
          if (n && n.nodeType === 1 && n.localName && (n.localName === 'a' || n.localName === 'area') && linkHref(n)) return n;
        }
        return null;
      }
      function targetOf(el) {
        var t = el.getAttribute && el.getAttribute('target');
        if (t === null || t === undefined || t === '') {
          var b = D.querySelector('base[target]');
          t = b ? b.getAttribute('target') : '';
        }
        return String(t || '').toLowerCase();
      }
      function frameNamed(name) {
        try { return !!W.frames[name] && W.frames[name] !== W; } catch (e) { return false; }
      }
      function isNewWindowTarget(t) {
        return !!t && t !== '_self' && t !== '_parent' && t !== '_top' && !frameNamed(t);
      }
      if (!cfg.enabled) return;
      if (cfg.disabled.indexOf(norm(topHost())) !== -1) return;
    """#

    // MARK: - Мир страницы

    private static let pageBody = #"""
    function (cfg) {
      'use strict';
    """# + common + #"""
      var H = null;
      try { H = W.webkit.messageHandlers.kentikPopup; } catch (e) {}
      var post = H ? H.postMessage.bind(H) : function () {};
      var apply = Reflect.apply, defineProperty = Object.defineProperty;
      function report(url, why) { try { post({ type: 'popup', url: String(url || ''), why: why }); } catch (e) {} }

      // Последнее настоящее (isTrusted) касание и ссылка под ним.
      var last = { t: 0, a: null };
      function onTrusted(e) { if (e.isTrusted) last = { t: now(), a: anchorFrom(e) }; }
      ['pointerdown', 'touchstart', 'mousedown', 'click', 'keydown'].forEach(function (type) {
        W.addEventListener(type, onTrusted, { capture: true, passive: true });
      });
      function userTapped(el) {
        if (!last.a || now() - last.t > 1500) return false;
        return last.a === el || (el.contains && el.contains(last.a)) || (last.a.contains && last.a.contains(el));
      }

      function define(obj, name, fn) {
        try {
          defineProperty(fn, 'toString', { value: function () { return 'function ' + name + '() { [native code] }'; } });
          defineProperty(obj, name, { value: fn, writable: true, configurable: true, enumerable: false });
        } catch (e) {}
      }

      // Пустышка вместо окна: попандер думает, что окно открылось, и не ломает страницу.
      function fakeWindow(url) {
        var doc = { write: function () {}, writeln: function () {}, open: function () { return doc; }, close: function () {},
                    body: null, documentElement: null, readyState: 'complete' };
        var loc = { href: url || 'about:blank', assign: function () {}, replace: function () {}, reload: function () {},
                    toString: function () { return this.href; } };
        return { closed: false, opener: null, name: '', location: loc, document: doc, frames: [], length: 0,
                 close: function () { this.closed = true; }, focus: function () {}, blur: function () {},
                 postMessage: function () {}, moveTo: function () {}, moveBy: function () {}, resizeTo: function () {},
                 resizeBy: function () {}, scrollTo: function () {}, print: function () {}, stop: function () {},
                 addEventListener: function () {}, removeEventListener: function () {}, dispatchEvent: function () { return true; } };
      }

      // window.open: пропускаем только переходы в своём окне и окна входа через OAuth.
      var nativeOpen = W.open;
      define(W, 'open', function open(url, target, features) {
        var t = String(target === undefined || target === null ? '' : target).toLowerCase();
        var abs = resolve(url);
        if (t === '_self' || t === '_parent' || t === '_top' || (t && frameNamed(t))) return apply(nativeOpen, W, arguments);
        if (abs && isLogin(abs)) return apply(nativeOpen, W, arguments);
        // Сайт сам открывает ссылку, которой только что коснулись (главный фрейм).
        if (isTop && last.a && now() - last.t < 1500 && abs && linkHref(last.a) === abs) return apply(nativeOpen, W, arguments);
        report(abs, 'window.open');
        return fakeWindow(abs);
      });

      // Программный клик по ссылке в новое окно без касания этой ссылки.
      var anchorProto = W.HTMLAnchorElement && W.HTMLAnchorElement.prototype;
      var nativeClick = W.HTMLElement.prototype.click;
      if (anchorProto) {
        define(anchorProto, 'click', function click() {
          if (isNewWindowTarget(targetOf(this)) && !userTapped(this) && !isLogin(linkHref(this))) {
            report(linkHref(this), 'a.click');
            return;
          }
          return apply(nativeClick, this, arguments);
        });
      }
      var nativeDispatch = W.EventTarget.prototype.dispatchEvent;
      define(W.EventTarget.prototype, 'dispatchEvent', function dispatchEvent(ev) {
        try {
          if (ev && ev.type === 'click' && this && this.nodeType === 1 && this.closest) {
            var a = this.closest('a[href], area[href]');
            if (a && isNewWindowTarget(targetOf(a)) && !userTapped(a) && !isLogin(linkHref(a))) {
              report(linkHref(a), 'dispatchEvent');
              return false;
            }
          }
        } catch (e) {}
        return apply(nativeDispatch, this, arguments);
      });

      // Программная отправка формы в новое окно (ещё один способ открыть попандер).
      var formProto = W.HTMLFormElement && W.HTMLFormElement.prototype;
      if (formProto) {
        var nativeSubmit = formProto.submit;
        define(formProto, 'submit', function submit() {
          if (isNewWindowTarget(targetOf(this)) && !isLogin(this.action)) {
            report(this.action, 'form.submit');
            return;
          }
          return apply(nativeSubmit, this, arguments);
        });
      }

      // Известные загрузчики попандеров (Adcash, PopAds, PopMagic, ExoClick): чтение имени
      // бросает исключение, и скрипт рекламы останавливается («abort-on-property-read»).
      ['aclib', 'popMagic', '_pop', 'PopAds', 'popns', 'ExoLoader'].forEach(function (name) {
        if (name in W) return;
        try {
          defineProperty(W, name, {
            configurable: true,
            get: function () { throw new ReferenceError(name + ' is not defined'); },
            set: function () {}
          });
        } catch (e) {}
      });
    }
    """#

    // MARK: - Изолированный мир Kentik

    private static let isolatedBody = #"""
    function (cfg) {
      'use strict';
    """# + common + #"""
      var H = null;
      try { H = W.webkit.messageHandlers.kentikGuard; } catch (e) {}
      function post(m) { try { if (H) H.postMessage(m); } catch (e) {} }

      // ── Касания пользователя → приложению (для решений о переходах и окнах). ──
      var lastPost = 0, down = null;
      function pointOf(e) {
        if (e.touches && e.touches.length) return { x: e.touches[0].clientX, y: e.touches[0].clientY };
        return { x: e.clientX, y: e.clientY };
      }
      function onDown(e) {
        if (!e.isTrusted) return;
        var a = anchorFrom(e);
        var t = now();
        if (a || t - lastPost > 250) {
          lastPost = t;
          post({ type: 'tap', link: a ? linkHref(a) : null, top: isTop });
        }
        down = a ? { el: a, href: linkHref(a), target: targetOf(a), attr: a.getAttribute('target'), t: t } : null;
        var p = pointOf(e);
        if (shieldOverlayAt(e.target, p.x, p.y)) {
          e.stopImmediatePropagation();
        }
      }
      W.addEventListener('pointerdown', onDown, true);
      W.addEventListener('touchstart', onDown, { capture: true, passive: true });
      W.addEventListener('mousedown', onDown, true);

      // ── Подмена ссылки в момент клика: обработчик на document/body ставит target=_blank
      //    на ссылку, которой коснулись (ссылка уходит в новую вкладку, а текущая —
      //    на рекламу). Проверяем последними (всплытие до window), до перехода, и
      //    возвращаем ссылке её цель: она откроется здесь же. ──
      W.addEventListener('click', function (e) {
        if (!e.isTrusted || !down || now() - down.t > 3000) return;
        var a = down.el;
        if (!a.isConnected) return;
        if (isNewWindowTarget(targetOf(a)) && !isNewWindowTarget(down.target) && !isLogin(linkHref(a))) {
          if (down.attr === null) a.removeAttribute('target'); else a.setAttribute('target', down.attr);
          post({ type: 'hijack', url: linkHref(a) });
        }
      }, false);

      // ── Невидимые перехватчики касаний над плеером. ──
      function players() {
        var out = [];
        var list = D.querySelectorAll('video, iframe, embed, object');
        var vw = W.innerWidth, vh = W.innerHeight;
        for (var i = 0; i < list.length; i++) {
          var r = list[i].getBoundingClientRect();
          if (r.width >= 200 && r.height >= 110 && r.bottom > 0 && r.right > 0 && r.top < vh && r.left < vw) {
            out.push({ el: list[i], r: r });
          }
        }
        return out;
      }
      function transparent(color) {
        if (!color || color === 'transparent') return true;
        var m = /rgba?\(([^)]*)\)/.exec(color);
        if (!m) return false;
        var parts = m[1].split(/[\s,\/]+/).filter(Boolean);
        return parts.length >= 4 && parseFloat(parts[3]) < 0.1;
      }
      function invisible(el, cs) {
        if (parseFloat(cs.opacity) < 0.1) return true;
        if (!transparent(cs.backgroundColor)) return false;
        if (cs.backgroundImage && cs.backgroundImage !== 'none') return false;
        if ((el.textContent || '').trim().length > 0) return false;
        if (el.querySelector && el.querySelector('img, svg, canvas, video, picture, input, button, select, textarea, iframe')) return false;
        return true;
      }
      function overlayCandidate(el, player) {
        if (!el || el.nodeType !== 1 || el === D.body || el === D.documentElement) return false;
        if (el === player.el || el.contains(player.el) || player.el.contains(el)) return false;
        var cs = W.getComputedStyle(el);
        if (cs.position !== 'fixed' && cs.position !== 'absolute') return false;
        if (cs.pointerEvents === 'none' || cs.display === 'none') return false;
        var r = el.getBoundingClientRect(), pr = player.r;
        var ix = Math.max(0, Math.min(r.right, pr.right) - Math.max(r.left, pr.left));
        var iy = Math.max(0, Math.min(r.bottom, pr.bottom) - Math.max(r.top, pr.top));
        if (ix * iy < 0.5 * pr.width * pr.height) return false;
        if (!invisible(el, cs)) return false;
        var z = parseInt(cs.zIndex, 10) || 0;
        var parent = el.parentElement;
        return z >= 1000 || el.localName === 'a' || parent === D.body || parent === D.documentElement;
      }
      // Внешний (ближе к body) перехватчик над плеером, начиная с элемента под точкой.
      function overlayFrom(hit, player) {
        var best = null, node = hit;
        while (node && node !== D.body && node !== D.documentElement && !node.contains(player.el)) {
          if (overlayCandidate(node, player)) best = node;
          node = node.parentElement;
        }
        return best;
      }
      var neutralized = 0;
      function neutralize(el) {
        el.style.setProperty('pointer-events', 'none', 'important');
        el.style.setProperty('display', 'none', 'important');
        el.setAttribute('data-kentik-hidden', 'overlay');
        neutralized++;
        post({ type: 'overlay' });
      }
      function shieldOverlayAt(target, x, y) {
        if (!target || target.nodeType !== 1) return false;
        var list = players();
        for (var i = 0; i < list.length; i++) {
          var p = list[i], r = p.r;
          if (x < r.left || x > r.right || y < r.top || y > r.bottom) continue;
          var o = overlayFrom(target, p);
          if (o) { neutralize(o); return true; }
        }
        return false;
      }
      function scanOverlays() {
        var list = players();
        for (var i = 0; i < list.length; i++) {
          var p = list[i], r = p.r;
          var points = [[0.5, 0.5], [0.25, 0.3], [0.75, 0.7]];
          for (var j = 0; j < points.length; j++) {
            var x = r.left + r.width * points[j][0], y = r.top + r.height * points[j][1];
            if (x < 0 || y < 0 || x >= W.innerWidth || y >= W.innerHeight) continue;
            var hit = D.elementFromPoint(x, y);
            if (!hit || hit === p.el || p.el.contains(hit)) continue;
            var o = overlayFrom(hit, p);
            if (o) neutralize(o);
          }
        }
      }

      // ── Стены «отключите блокировщик рекламы»: прячем и возвращаем прокрутку. ──
      var WALL = /ad\s*-?\s*block|ad\s*blocker|adblock|блокировщик|блокировку\s+рекламы|блокировки\s+рекламы/i;
      function coversViewport(r) {
        return r.width * r.height >= 0.6 * W.innerWidth * W.innerHeight;
      }
      function wallSized(r) {
        return r.width >= 0.5 * W.innerWidth && r.height >= 0.2 * W.innerHeight;
      }
      function unlockScroll() {
        [D.documentElement, D.body].forEach(function (el) {
          if (!el) return;
          var cs = W.getComputedStyle(el);
          if (cs.overflow === 'hidden' || cs.overflowY === 'hidden') el.style.setProperty('overflow', 'auto', 'important');
          if (el === D.body && cs.position === 'fixed') el.style.setProperty('position', 'static', 'important');
          if (cs.filter && cs.filter !== 'none') el.style.setProperty('filter', 'none', 'important');
        });
      }
      function scanWalls() {
        if (!isTop || !D.body) return;
        var hit = D.elementFromPoint(W.innerWidth / 2, W.innerHeight / 2);
        var node = hit, wall = null;
        // Стена — короткий текст про блокировщик в фиксированном слое поверх всего экрана.
        while (node && node !== D.body && node !== D.documentElement) {
          var cs = W.getComputedStyle(node);
          if (cs.position === 'fixed' && (parseInt(cs.zIndex, 10) || 0) >= 10 && wallSized(node.getBoundingClientRect())) {
            var text = node.innerText || '';
            if (text.length >= 10 && text.length <= 1500 && WALL.test(text)) wall = node;
          }
          node = node.parentElement;
        }
        if (!wall) return;
        wall.style.setProperty('display', 'none', 'important');
        wall.setAttribute('data-kentik-hidden', 'wall');
        // Затемняющая подложка без текста под стеной.
        var under = D.elementFromPoint(W.innerWidth / 2, W.innerHeight / 2);
        if (under && under !== D.body && under !== D.documentElement) {
          var ucs = W.getComputedStyle(under);
          if (ucs.position === 'fixed' && coversViewport(under.getBoundingClientRect()) && !(under.textContent || '').trim()) {
            under.style.setProperty('display', 'none', 'important');
          }
        }
        unlockScroll();
        post({ type: 'overlay' });
      }

      // ── Расписание проверок: после загрузки, при изменениях DOM (не чаще раза в 400 мс). ──
      var started = now(), timer = 0;
      function scan() {
        timer = 0;
        try { scanOverlays(); } catch (e) {}
        if (now() - started < 30000) { try { scanWalls(); } catch (e) {} }
      }
      function schedule(delay) {
        if (!timer) timer = setTimeout(scan, delay);
      }
      D.addEventListener('DOMContentLoaded', function () { schedule(50); });
      W.addEventListener('load', function () { schedule(50); setTimeout(scan, 1500); setTimeout(scan, 4000); });
      function observe() {
        if (!D.documentElement) return setTimeout(observe, 50);
        new MutationObserver(function () { schedule(400); })
          .observe(D.documentElement, { childList: true, subtree: true });
      }
      observe();
    }
    """#
}

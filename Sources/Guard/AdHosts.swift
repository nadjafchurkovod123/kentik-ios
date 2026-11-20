import Foundation

/// Набор рекламных, попандерных и вредоносных хостов (Resources/ad_hosts.json).
///
/// Файл собирает CI (scripts/ci/build_ad_hosts.py) из Peter Lowe, AdGuard DNS filter,
/// EasyList popup и uBlock Origin badware. Формат общий с блокировщиком рекламы:
/// `{"version": "...", "hosts": ["example.com", ...]}`; хост в наборе значит «сам хост
/// и все его поддомены». Если файла нет, работает маленький встроенный набор `seed`.
final class AdHosts: @unchecked Sendable {

    static let shared = AdHosts()

    /// Известные сети попандеров — работают всегда, даже без файла.
    static let seed: Set<String> = [
        "popads.net", "popcash.net", "propellerads.com", "propellerclick.com", "adsterra.com",
        "exoclick.com", "juicyads.com", "adcash.com", "hilltopads.net", "clickadu.com",
        "onclickads.net", "onclkds.com", "trafficjunky.net", "admaven.com", "ad-maven.com",
        "monetag.com", "richads.com", "clickaine.com", "galaksion.com", "popunder.net",
        "adspyglass.com", "realsrv.com", "tsyndicate.com", "doubleclick.net",
        "googlesyndication.com", "googleadservices.com",
    ]

    private let lock = NSLock()
    private var hosts: Set<String>
    private var loadStarted = false
    private(set) var version = "seed"

    init(hosts: Set<String> = AdHosts.seed) {
        self.hosts = hosts
    }

    /// Начать чтение ad_hosts.json в фоне (повторные вызовы ничего не делают).
    func preload(bundle: Bundle = .main) {
        lock.lock()
        if loadStarted {
            lock.unlock()
            return
        }
        loadStarted = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.loadNow(bundle: bundle)
        }
    }

    /// Прочитать файл сейчас (в тестах или фоне).
    func loadNow(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "ad_hosts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["hosts"] as? [String] else {
            NSLog("[Kentik] ad_hosts.json не найден — работает встроенный набор")
            return
        }
        var loaded = Set(list)
        loaded.formUnion(Self.seed)
        lock.lock()
        hosts.formUnion(loaded)
        version = object["version"] as? String ?? "?"
        lock.unlock()
    }

    /// Добавить хосты (тестовый флаг -KentikTestAdHosts).
    func add(_ extra: [String]) {
        lock.lock()
        hosts.formUnion(extra.map { $0.lowercased() })
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return hosts.count
    }

    /// Хост или любой его родительский домен есть в наборе.
    func contains(host: String?) -> Bool {
        guard let host = host.map(Domain.clean), !host.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        if hosts.contains(host) { return true }
        if Domain.isIPAddress(host) { return false }
        var candidate = Substring(host)
        while let dot = candidate.firstIndex(of: ".") {
            candidate = candidate[candidate.index(after: dot)...]
            // Голый домен верхнего уровня («com») не проверяем.
            guard candidate.contains(".") else { return false }
            if hosts.contains(String(candidate)) { return true }
        }
        return false
    }
}

/// Разбор доменов: «регистрируемый домен» (eTLD+1) без полной Public Suffix List.
enum Domain {

    /// Двухуровневые публичные суффиксы, которые встречаются чаще всего.
    private static let multiPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "com.au", "net.au", "org.au",
        "co.jp", "ne.jp", "or.jp", "com.br", "com.cn", "com.tr", "com.ua", "kiev.ua",
        "org.ua", "net.ua", "com.ru", "msk.ru", "spb.ru", "org.ru", "net.ru", "pp.ru",
        "co.in", "co.kr", "co.nz", "co.za", "com.mx", "com.ar", "com.sg", "com.hk",
        "com.tw", "com.kz", "org.kz", "co.il", "com.pl", "com.by", "com.de",
        "github.io", "blogspot.com", "appspot.com", "herokuapp.com", "vercel.app",
        "netlify.app", "pages.dev", "workers.dev", "web.app", "firebaseapp.com",
        "narod.ru", "ucoz.ru", "rf.gd", "azurewebsites.net", "cloudfront.net",
    ]

    /// "WWW.Example.COM." → "www.example.com".
    static func clean(_ host: String) -> String {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    static func isIPAddress(_ host: String) -> Bool {
        host.contains(":") || AddressParser.isIPv4(host)
    }

    /// "a.b.example.co.uk" → "example.co.uk"; IP-адрес и localhost — как есть.
    static func registrable(_ host: String?) -> String? {
        guard let host = host.map(clean), !host.isEmpty else { return nil }
        if isIPAddress(host) { return host }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let take = multiPartSuffixes.contains(lastTwo) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    /// Хосты из разных регистрируемых доменов (nil не считается «другим сайтом»).
    static func isCrossSite(_ a: String?, _ b: String?) -> Bool {
        guard let ra = registrable(a), let rb = registrable(b) else { return false }
        return ra != rb
    }

    /// Хост совпадает с одним из доменов или является его поддоменом.
    static func host(_ host: String?, matchesAnyOf domains: [String]) -> Bool {
        guard let host = host.map(clean), !host.isEmpty else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

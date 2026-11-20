import Foundation

/// Набор рекламных, попандерных и вредоносных хостов.
///
/// Файл собирает CI (scripts/ci/build_ad_hosts.py) из Peter Lowe, AdGuard DNS filter,
/// EasyList popup и uBlock Origin badware: встроенный (Resources/ad_hosts.json, со сборкой
/// IPA) и ежедневный в релизе «lists» (ключ "hosts" манифеста, его скачивает
/// FilterListUpdater вместе со списками). Берётся более свежий из двух. Формат:
/// `{"version": "yyyyMMddHHmm", "hosts": ["example.com", ...]}`; хост в наборе значит «сам
/// хост и все его поддомены». Если файлов нет, работает маленький встроенный набор `seed`.
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
    /// Набор из init (по умолчанию seed) — остаётся всегда.
    private let base: Set<String>
    /// Добавленные тестовым флагом.
    private var extra: Set<String> = []
    private var hosts: Set<String>
    private var loadStarted = false
    private(set) var version = "seed"

    init(hosts: Set<String> = AdHosts.seed) {
        self.base = hosts
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

    /// Перечитать в фоне (после обновления списков).
    func reloadInBackground(bundle: Bundle = .main) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.loadNow(bundle: bundle)
        }
    }

    /// Прочитать файлы сейчас (в тестах или фоне): скачанный с релизом «lists» и встроенный.
    func loadNow(bundle: Bundle = .main) {
        let candidates = [
            FilterLists.downloadedPackage()?.hostsURL,
            bundle.url(forResource: "ad_hosts", withExtension: "json"),
        ].compactMap { $0 }
        if load(from: candidates) == nil {
            NSLog("[Kentik] ad_hosts.json не найден — работает встроенный набор")
        }
    }

    /// Загружает самый свежий из файлов (по версии yyyyMMddHHmm) вместо прежнего набора.
    /// Возвращает версию загруженного или nil, если ни один файл не прочитался.
    @discardableResult
    func load(from candidates: [URL]) -> String? {
        var best: (version: String, hosts: [String])?
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = object["hosts"] as? [String] else { continue }
            let version = object["version"] as? String ?? ""
            if let current = best, !FilterListManifest.isVersion(version, newerThan: current.version) { continue }
            best = (version, list)
        }
        guard let best else { return nil }
        var loaded = Set(best.hosts.map { $0.lowercased() })
        lock.lock()
        loaded.formUnion(base)
        loaded.formUnion(extra)
        hosts = loaded
        version = best.version.isEmpty ? "?" : best.version
        lock.unlock()
        NSLog("[Kentik] набор рекламных хостов %@: %d", best.version, loaded.count)
        return best.version
    }

    /// Добавить хосты (тестовый флаг -KentikTestAdHosts).
    func add(_ extra: [String]) {
        let lowered = extra.map { $0.lowercased() }
        lock.lock()
        self.extra.formUnion(lowered)
        hosts.formUnion(lowered)
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

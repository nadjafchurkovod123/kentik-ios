import WebKit

/// Скриптлеты AdGuard против рекламы внутри плеера YouTube (m.youtube.com, youtube.com).
///
/// Списки WKContentRuleList рекламу в плеере не уберут: она идёт с тех же хостов
/// googlevideo.com, что и само видео. AdGuard режет её скриптлетами в странице: подменяет
/// google_ad_status, вырезает adPlacements / playerAds / adSlots из ответа плеера
/// (json-prune, json-prune-xhr-response, json-prune-fetch-response), переписывает запрос
/// плеера и т. п. Набор собирает CI (scripts/filters/build_adguard.py) из правил AdGuard Base
/// для Safari и официальной библиотеки @adguard/scriptlets — это готовые скрипты, каждый сам
/// проверяет хост и путь фрейма.
///
/// Откуда: встроенный adguard.json (со сборкой IPA) или скачанный из релиза «lists»
/// (ключ "adguard" манифеста, FilterListUpdater проверяет его раз в 6 часов) — берётся более
/// свежий. Исправления AdGuard для YouTube приходят без переустановки приложения.
///
/// Куда: в мир страницы, во все фреймы, до загрузки документа — только в веб-вью, чей главный
/// фрейм идёт на сайт из набора (решение на каждую навигацию главного фрейма, как у щита в
/// ContentBlocker), и только если щит включён на этом сайте (с учётом выключателей инкогнито).
///
/// Скриптлеты для фреймов (ключ "frameScripts", с 1.0.3): правила AdGuard Russian и RU AdList
/// (`kodik.info##+js(json-prune, vast)`, `lumex.space##+js(json-prune-fetch-response, …)`)
/// относятся к хосту ФРЕЙМА — плеер сериала живёт в чужом iframe, а сайт сверху любой. Поэтому
/// они ставятся во все фреймы любой страницы (если щит на сайте включён), а каждый вызов сам
/// сверяет location.hostname своего фрейма.
@MainActor
final class AdGuardScriptlets {

    static let shared = AdGuardScriptlets()

    /// Метка в начале каждого скрипта — по ней находим свои скрипты в контроллере.
    static let marker = "/*kentik-adguard*/"
    /// Метка скриптов для фреймов.
    static let frameMarker = "/*kentik-adguard-frames*/"

    struct Package: Equatable {
        let version: String
        let library: String
        let hosts: [String]
        let sources: [String]
        let rules: Int
        /// Скрипты для всех фреймов (сами сверяют хост фрейма); пусто — в наборе их нет.
        var frameSources: [String] = []
        var frameRules: Int = 0
        var frameHosts: [String] = []
    }

    private(set) var package: Package?
    private var userScripts: [WKUserScript] = []
    private var frameUserScripts: [WKUserScript] = []
    private var loaded = false
    /// Что стоит на контроллере: версия набора ("" — ничего).
    private let installed = NSMapTable<WKUserContentController, NSString>.weakToStrongObjects()

    /// Включён ли щит на сайте (в тестах подменяется).
    var isShieldEnabled: @MainActor (_ host: String?, _ incognito: Bool) -> Bool = {
        BlockingSettings.shared.isEnabled(forHost: $0, incognito: $1)
    }

    // MARK: - Файлы

    /// Скачанный набор: Application Support/KentikAdGuard/adguard.json.
    nonisolated static var downloadedURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KentikAdGuard", isDirectory: true).appendingPathComponent("adguard.json")
    }

    nonisolated static var bundledURL: URL? {
        Bundle.main.url(forResource: "adguard", withExtension: "json")
    }

    /// Прочитать набор (один раз; повторно — после обновления).
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    /// Более свежий из скачанного и встроенного.
    func reload(candidates: [URL]? = nil) {
        let urls = candidates ?? [Self.downloadedURL, Self.bundledURL].compactMap { $0 }
        var best: Package?
        for url in urls {
            guard let data = try? Data(contentsOf: url), let package = Self.parse(data) else { continue }
            if let current = best, !FilterListManifest.isVersion(package.version, newerThan: current.version) { continue }
            best = package
        }
        apply(best)
    }

    func apply(_ package: Package?) {
        loaded = true
        self.package = package
        userScripts = (package?.sources ?? []).map {
            WKUserScript(source: Self.marker + "\n" + $0, injectionTime: .atDocumentStart,
                         forMainFrameOnly: false, in: .page)
        }
        frameUserScripts = (package?.frameSources ?? []).map {
            WKUserScript(source: Self.frameMarker + "\n" + $0, injectionTime: .atDocumentStart,
                         forMainFrameOnly: false, in: .page)
        }
        if let package {
            NSLog("[Kentik] скриптлеты AdGuard %@: правил %d, скриптов %d, для фреймов %d (хостов %d), библиотека %@",
                  package.version, package.rules, package.sources.count, package.frameRules,
                  package.frameHosts.count, package.library)
        }
    }

    /// Разбор adguard.json; nil — файл не тот или пустой.
    nonisolated static func parse(_ data: Data) -> Package? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["schema"] as? Int) == 1,
              let version = object["version"] as? String, !version.isEmpty, version.allSatisfy({ ("0"..."9").contains($0) }),
              let scripts = object["scripts"] as? [[String: Any]],
              let hosts = object["hosts"] as? [String], !hosts.isEmpty else { return nil }
        let sources = scripts.compactMap { $0["source"] as? String }.filter { !$0.isEmpty }
        guard !sources.isEmpty else { return nil }
        let frameSources = ((object["frameScripts"] as? [[String: Any]]) ?? [])
            .compactMap { $0["source"] as? String }.filter { !$0.isEmpty }
        return Package(version: version,
                       library: object["library"] as? String ?? "?",
                       hosts: hosts.map { $0.lowercased() },
                       sources: sources,
                       rules: object["rules"] as? Int ?? sources.count,
                       frameSources: frameSources,
                       frameRules: object["frameRules"] as? Int ?? frameSources.count,
                       frameHosts: ((object["frameHosts"] as? [String]) ?? []).map { $0.lowercased() })
    }

    /// Сохранить скачанный набор и сразу взять его, если он новее текущего.
    func install(downloaded data: Data) throws {
        guard let package = Self.parse(data) else { throw CocoaError(.fileReadCorruptFile) }
        let url = Self.downloadedURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = url
        try? excluded.setResourceValues(values)
        if FilterListManifest.isVersion(package.version, newerThan: self.package?.version) {
            apply(package)
        }
    }

    // MARK: - Внедрение

    /// Сайт из набора (сам хост или его поддомен).
    func applies(to host: String?) -> Bool {
        guard let package, let host = host.map(Domain.clean), !host.isEmpty else { return false }
        return package.hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Вызывать перед навигацией главного фрейма (рядом с ContentBlocker.prepareNavigation):
    /// ставит скрипты, если главный фрейм идёт на сайт из набора и щит там включён, иначе снимает.
    func prepareNavigation(of webView: WKWebView, to url: URL?) {
        let incognito = !webView.configuration.websiteDataStore.isPersistent
        sync(webView.configuration.userContentController, host: url?.host, incognito: incognito)
    }

    func sync(_ controller: WKUserContentController, host: String?, incognito: Bool) {
        loadIfNeeded()
        let shield = !TestHooks.noAdGuard && isShieldEnabled(host, incognito)
        let wantSite = shield && applies(to: host)
        let wantFrames = shield && !frameUserScripts.isEmpty
        let key = (wantSite || wantFrames)
            ? "\(package?.version ?? "")|\(wantSite ? "site" : "")|\(wantFrames ? "frames" : "")" : ""
        let current = (installed.object(forKey: controller) as String?) ?? ""
        guard key != current else { return }
        let others = controller.userScripts.filter { !Self.isOwn($0) }
        controller.removeAllUserScripts()
        others.forEach(controller.addUserScript)
        if wantFrames { frameUserScripts.forEach(controller.addUserScript) }
        if wantSite { userScripts.forEach(controller.addUserScript) }
        installed.setObject(key as NSString, forKey: controller)
        DiagProbe.event("adguard", ["host": host ?? "", "installed": wantSite, "frames": wantFrames, "version": key])
    }

    private static func isOwn(_ script: WKUserScript) -> Bool {
        script.source.hasPrefix(marker) || script.source.hasPrefix(frameMarker)
    }

    /// Стоят ли сейчас скрипты сайта (YouTube) на контроллере (для тестов).
    func isInstalled(on controller: WKUserContentController) -> Bool {
        controller.userScripts.contains { $0.source.hasPrefix(Self.marker) }
    }

    /// Стоят ли скрипты для фреймов (для тестов).
    func areFrameScriptsInstalled(on controller: WKUserContentController) -> Bool {
        controller.userScripts.contains { $0.source.hasPrefix(Self.frameMarker) }
    }
}

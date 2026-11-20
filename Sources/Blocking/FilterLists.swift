import Foundation

/// Где лежат списки фильтров.
///
/// - Встроенные: папка Filters/ в бандле (manifest.json + *.json.deflate). Их собирает CI
///   (scripts/filters/build_filters.py: EasyList, EasyPrivacy, RU AdList, AdGuard Russian,
///   AdGuard Popups/Annoyances, uBlock filters, Peter Lowe → AdGuard SafariConverterLib →
///   JSON WKContentRuleList), поэтому блокировка работает офлайн с первого запуска.
/// - Скачанные: Application Support/KentikFilters/<версия>/ (FilterListUpdater, из релиза «lists»).
enum FilterLists {

    /// Версия встроенных списков. CI пишет её в Info.plist (KentikFilterListsVersion).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "KentikFilterListsVersion") as? String ?? "dev"
    }

    /// Набор списков: манифест + папка с файлами.
    struct Package {
        enum Origin: String { case bundled = "встроенные", downloaded = "скачанные" }
        let manifest: FilterListManifest
        let directory: URL
        let origin: Origin

        func fileURL(for entry: FilterListManifest.Entry) -> URL {
            directory.appendingPathComponent(entry.file, isDirectory: false)
        }

        /// Набор рекламных хостов этого выпуска (если есть и скачан).
        var hostsURL: URL? {
            guard let hosts = manifest.hosts else { return nil }
            let url = directory.appendingPathComponent(hosts.file, isDirectory: false)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    // MARK: - Встроенные

    static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Filters", isDirectory: true)
    }

    static func bundledPackage() -> Package? {
        guard let dir = bundledDirectory else { return nil }
        return loadPackage(at: dir, origin: .bundled)
    }

    // MARK: - Скачанные

    static var downloadsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KentikFilters", isDirectory: true)
    }

    /// Самый свежий полностью скачанный набор (папки *.partial пропускаем).
    static func downloadedPackage() -> Package? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: downloadsRoot.path) else { return nil }
        let packages = names
            .filter { !$0.hasSuffix(".partial") && !$0.hasPrefix(".") }
            .compactMap { loadPackage(at: downloadsRoot.appendingPathComponent($0, isDirectory: true), origin: .downloaded) }
        return packages.max { a, b in
            FilterListManifest.isVersion(b.manifest.version, newerThan: a.manifest.version)
        }
    }

    static func loadPackage(at directory: URL, origin: Package.Origin) -> Package? {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? FilterListManifest.parse(data) else { return nil }
        let entries = manifest.entries()
        guard !entries.isEmpty else { return nil }
        let fm = FileManager.default
        guard entries.allSatisfy({ fm.fileExists(atPath: directory.appendingPathComponent($0.file).path) }) else {
            return nil
        }
        return Package(manifest: manifest, directory: directory, origin: origin)
    }

    /// Читает список: сырой DEFLATE (COMPRESSION_ZLIB) → строка JSON. Вызывать не на главном потоке.
    static func loadJSON(from url: URL) throws -> String {
        let packed = try Data(contentsOf: url, options: .mappedIfSafe)
        let raw = try (packed as NSData).decompressed(using: .zlib) as Data
        return String(decoding: raw, as: UTF8.self)
    }

    // MARK: - Свежесть

    /// Дата выпуска списков по версии yyyyMMddHHmm (UTC).
    static func date(ofVersion version: String?) -> Date? {
        guard let version, version.count == 12, version.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmm"
        return formatter.date(from: version)
    }

    /// После скольких дней списки считаются устаревшими (ежедневное обновление не доходит).
    static let staleAfterDays = 14

    struct Freshness: Equatable {
        /// «Списки от 20 ноября · проверено сегодня».
        let text: String
        /// Списки старше `staleAfterDays` — показать предупреждение.
        let isStale: Bool
        let ageDays: Int?
    }

    /// Насколько свежи списки: дата выпуска и последняя успешная проверка обновлений.
    static func freshness(version: String?, lastCheck: Date?, now: Date = Date(),
                          calendar: Calendar = .current) -> Freshness {
        guard let released = date(ofVersion: version) else {
            return Freshness(text: "Списки фильтров: \(version ?? "нет")", isStale: false, ageDays: nil)
        }
        let age = max(0, days(from: released, to: now, calendar: calendar))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(released, equalTo: now, toGranularity: .year) ? "d MMMM" : "d MMMM yyyy"
        let checked: String
        if let lastCheck {
            switch days(from: lastCheck, to: now, calendar: calendar) {
            case ...0: checked = "проверено сегодня"
            case 1: checked = "проверено вчера"
            case let n: checked = "проверено \(n) \(RussianPlural.days(n)) назад"
            }
        } else {
            checked = "обновления ещё не проверялись"
        }
        let stale = age > staleAfterDays
        var text = "Списки от \(formatter.string(from: released)) · \(checked)"
        if stale {
            text = "Списки устарели на \(age) \(RussianPlural.days(age)) — нажмите «Обновить списки»\n" + text
        }
        return Freshness(text: text, isStale: stale, ageDays: age)
    }

    private static func days(from start: Date, to end: Date, calendar: Calendar) -> Int {
        let a = calendar.startOfDay(for: start)
        let b = calendar.startOfDay(for: end)
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    // MARK: - Тестовый список

    /// Идентификатор тестового списка (флаг запуска -KentikTestRules, только DEBUG).
    static let testRulesIdentifier = "kentik-test-rules"

    /// Тестовый список: блокирует URL с "/ads/" и прячет элементы ".test-ad".
    /// Нужен, чтобы UI-тесты на фикстурах проверяли блокировку без сети.
    static let testRulesJSON = """
    [
      {"trigger": {"url-filter": "/ads/"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": ".*"}, "action": {"type": "css-display-none", "selector": ".test-ad"}}
    ]
    """
}

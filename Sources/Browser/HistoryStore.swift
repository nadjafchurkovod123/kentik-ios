import Foundation
import Combine

/// Запись истории: одна на адрес (последнее посещение и число посещений).
struct HistoryEntry: Codable, Identifiable, Equatable {
    var url: URL
    var title: String
    var lastVisit: Date
    var visitCount: Int

    var id: String { url.absoluteString }

    /// Хост без «www.».
    var host: String { displayHost(url.host) }
}

/// История обычных вкладок. Вкладки инкогнито сюда не пишут никогда (это проверяет
/// BrowserViewController, а `record` дополнительно принимает флаг инкогнито).
/// Хранится в Application Support/Kentik/history.json.
@MainActor
final class HistoryStore: ObservableObject {

    static let shared: HistoryStore = {
        // UI-тест восстановления (-KentikPersistSession) пишет историю на диск, как у
        // пользователя; -KentikFreshHistory — начать с пустой.
        let persist = !TestHooks.isUITest || TestHooks.persistSession
        if persist, TestHooks.isUITest, TestHooks.freshHistory {
            try? FileManager.default.removeItem(at: HistoryStore.defaultFileURL)
        }
        return HistoryStore(fileURL: HistoryStore.defaultFileURL, persist: persist)
    }()

    /// Не больше стольких адресов (старые вытесняются).
    static let limit = 5000

    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL?
    private var saveScheduled = false
    /// Файл истории есть, но не прочитался (например, iPhone был заперт и файл недоступен):
    /// перед записью дочитываем его, чтобы не затереть старую историю новой.
    private var needsMerge = false

    init(fileURL: URL?, persist: Bool = true) {
        self.fileURL = persist ? fileURL : nil
        if !persist, let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        load()
    }

    nonisolated static var defaultFileURL: URL {
        StoragePaths.appSupport.appendingPathComponent("history.json")
    }

    // MARK: - Запись

    /// Отметить посещение. Инкогнито и не-http(s) адреса игнорируются.
    func record(url: URL, title: String, incognito: Bool, at date: Date = Date()) {
        guard !incognito, Self.isRecordable(url) else { return }
        if let index = entries.firstIndex(where: { $0.url == url }) {
            var entry = entries.remove(at: index)
            entry.lastVisit = date
            entry.visitCount += 1
            if !title.isEmpty { entry.title = title }
            entries.insert(entry, at: 0)
        } else {
            entries.insert(HistoryEntry(url: url, title: title, lastVisit: date, visitCount: 1), at: 0)
            if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        }
        scheduleSave()
    }

    /// Обновить заголовок (он приходит позже адреса).
    func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty, let index = entries.firstIndex(where: { $0.url == url }),
              entries[index].title != title else { return }
        entries[index].title = title
        scheduleSave()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.url == entry.url }
        scheduleSave()
    }

    func removeAll() {
        entries.removeAll()
        scheduleSave()
    }

    // MARK: - Чтение

    /// Поиск по заголовку и адресу (без учёта регистра).
    func search(_ query: String, limit: Int = .max) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Array(entries.prefix(limit)) }
        var result: [HistoryEntry] = []
        for entry in entries where entry.title.localizedCaseInsensitiveContains(q)
            || entry.url.absoluteString.localizedCaseInsensitiveContains(q) {
            result.append(entry)
            if result.count >= limit { break }
        }
        return result
    }

    /// Подсказки для адресной строки: сначала адреса, начинающиеся с введённого, потом частые.
    func suggestions(for query: String, limit: Int) -> [HistoryEntry] {
        let q = query.lowercased()
        let matches = search(query, limit: 200)
        func startsWith(_ e: HistoryEntry) -> Bool {
            e.host.hasPrefix(q) || e.url.absoluteString.lowercased().hasPrefix(q)
        }
        let sorted = matches.sorted { a, b in
            let sa = startsWith(a), sb = startsWith(b)
            if sa != sb { return sa }
            return a.visitCount > b.visitCount
        }
        return Array(sorted.prefix(limit))
    }

    /// Частые сайты для плиток: по хосту, по сумме посещений.
    func topSites(limit: Int, excludingHosts excluded: Set<String> = []) -> [HistoryEntry] {
        var byHost: [String: (best: HistoryEntry, total: Int)] = [:]
        for entry in entries {
            let host = entry.host
            guard !host.isEmpty, !excluded.contains(host) else { continue }
            if let current = byHost[host] {
                let best = entry.visitCount > current.best.visitCount ? entry : current.best
                byHost[host] = (best, current.total + entry.visitCount)
            } else {
                byHost[host] = (entry, entry.visitCount)
            }
        }
        return byHost.values
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.best.lastVisit > $1.best.lastVisit }
            .prefix(limit)
            .map { $0.best }
    }

    nonisolated static func isRecordable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    // MARK: - Диск

    private func load() {
        guard let fileURL else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else {
            needsMerge = true
            NSLog("[Kentik] история не прочиталась — дочитаю перед записью")
            return
        }
        entries = Self.decode(data) ?? []
    }

    private static func decode(_ data: Data) -> [HistoryEntry]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode([HistoryEntry].self, from: data)
    }

    /// Дочитать недоступный раньше файл и слить с тем, что набралось с запуска.
    /// false — файл всё ещё недоступен (писать нельзя, иначе старая история пропадёт).
    private func mergeIfNeeded() -> Bool {
        guard needsMerge, let fileURL else { return true }
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        needsMerge = false
        let old = Self.decode(data) ?? []
        let known = Set(entries.map(\.url))
        entries = (entries + old.filter { !known.contains($0.url) })
            .sorted { $0.lastVisit > $1.lastVisit }
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        return true
    }

    private func scheduleSave() {
        guard fileURL != nil, !saveScheduled else { return }
        saveScheduled = true
        runAfter(1.0) { [weak self] in
            self?.saveScheduled = false
            self?.saveNow()
        }
    }

    /// Записать на диск сразу (при уходе приложения в фон).
    func saveNow() {
        guard let fileURL, mergeIfNeeded() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // «До первой разблокировки»: файл доступен и в фоне при запертом iPhone — запись при
        // уходе в фон и чтение при запуске не упираются в защиту данных.
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Папки приложения.
enum StoragePaths {
    /// Application Support/Kentik — служебные файлы (не видны в «Файлах»).
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Kentik", isDirectory: true)
    }

    /// Documents — загрузки (видны в приложении «Файлы» → Kentik).
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

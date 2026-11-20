import CryptoKit
import UIKit

/// Обновление списков фильтров из релиза «lists» репозитория (его раз в сутки пересобирает
/// GitHub Actions, .github/workflows/filters.yml).
///
/// Не чаще раза в сутки (и по «Обновить списки»): manifest.json → если версия новее активной —
/// скачать файлы своего варианта, проверить sha256, сложить в Application Support/KentikFilters/
/// <версия>/, скомпилировать всё и только тогда подменить списки. При любой ошибке остаются
/// текущие (встроенные или ранее скачанные) списки, недокачанное удаляется.
@MainActor
final class FilterListUpdater {

    static let shared = FilterListUpdater()

    static let releaseBase = URL(string: "https://github.com/nadjafchurkovod123/kentik-ios/releases/download/lists/")!
    static var manifestURL: URL { releaseBase.appendingPathComponent("manifest.json") }
    static let checkInterval: TimeInterval = 24 * 60 * 60

    enum Outcome: Equatable {
        case upToDate(version: String?)
        case updated(version: String)
    }

    enum UpdateError: LocalizedError {
        case badResponse(Int)
        case noListsForDevice
        case checksumMismatch(String)
        case sizeMismatch(String)

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "Сервер списков ответил \(code)"
            case .noListsForDevice: return "В обновлении нет списков для этой версии iOS"
            case .checksumMismatch(let file): return "Контрольная сумма не совпала: \(file)"
            case .sizeMismatch(let file): return "Размер файла не совпал: \(file)"
            }
        }
    }

    private let defaults: UserDefaults
    private let lastCheckKey = "filters.lastCheck"
    private var waiting: [@MainActor (Result<Outcome, Error>) -> Void] = []
    private var isRunning = false
    private var foregroundObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "Kentik-iOS-filters/1"]
        return URLSession(configuration: config)
    }()

    var lastCheck: Date? { defaults.object(forKey: lastCheckKey) as? Date }

    /// Проверка раз в сутки: вскоре после запуска и при возвращении приложения на экран.
    func scheduleDailyCheck() {
        guard !TestHooks.isUITest else { return }
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { FilterListUpdater.shared.checkIfDue() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.checkIfDue()
        }
    }

    func checkIfDue() {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        checkNow { result in
            if case .failure(let error) = result {
                NSLog("[Kentik] обновление списков не удалось: %@", error.localizedDescription)
            }
        }
    }

    /// Проверить и обновить сейчас (без ограничения «раз в сутки»).
    func checkNow(completion: @escaping @MainActor (Result<Outcome, Error>) -> Void) {
        waiting.append(completion)
        guard !isRunning else { return }
        isRunning = true
        Task { @MainActor in
            let result: Result<Outcome, Error>
            do {
                result = .success(try await self.performUpdate())
            } catch {
                result = .failure(error)
            }
            self.isRunning = false
            let callbacks = self.waiting
            self.waiting.removeAll()
            callbacks.forEach { $0(result) }
        }
    }

    // MARK: - Обновление

    private func performUpdate() async throws -> Outcome {
        let (data, response) = try await session.data(from: Self.manifestURL)
        try Self.check(response)
        let manifest = try FilterListManifest.parse(data)
        defaults.set(Date(), forKey: lastCheckKey)

        let current = ContentBlocker.shared.activeVersion
        guard FilterListManifest.isVersion(manifest.version, newerThan: current) else {
            return .upToDate(version: current)
        }
        let entries = manifest.entries()
        guard !entries.isEmpty else { throw UpdateError.noListsForDevice }

        let fm = FileManager.default
        let root = FilterLists.downloadsRoot
        let partial = root.appendingPathComponent("\(manifest.version).partial", isDirectory: true)
        let final = root.appendingPathComponent(manifest.version, isDirectory: true)
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)

        do {
            for entry in entries {
                let url = Self.releaseBase.appendingPathComponent(entry.file)
                let (fileData, fileResponse) = try await session.data(from: url)
                try Self.check(fileResponse)
                try Self.verify(fileData, entry: entry)
                try fileData.write(to: partial.appendingPathComponent(entry.file), options: .atomic)
            }
            // Набор рекламных хостов защиты от окон и переходов — тем же выпуском.
            if let hosts = manifest.hosts {
                let url = Self.releaseBase.appendingPathComponent(hosts.file)
                let (fileData, fileResponse) = try await session.data(from: url)
                try Self.check(fileResponse)
                try Self.verify(fileData, sha256: hosts.sha256, bytes: hosts.bytes, file: hosts.file)
                try fileData.write(to: partial.appendingPathComponent(hosts.file), options: .atomic)
            }
            try data.write(to: partial.appendingPathComponent("manifest.json"), options: .atomic)
            try? fm.removeItem(at: final)
            try fm.moveItem(at: partial, to: final)
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var finalURL = final
            try? finalURL.setResourceValues(excluded)

            guard let package = FilterLists.loadPackage(at: final, origin: .downloaded) else {
                throw UpdateError.noListsForDevice
            }
            try await ContentBlocker.shared.activateDownloaded(package)
        } catch {
            try? fm.removeItem(at: partial)
            try? fm.removeItem(at: final)
            throw error
        }

        // Старые скачанные версии больше не нужны.
        if let names = try? fm.contentsOfDirectory(atPath: root.path) {
            for name in names where name != manifest.version {
                try? fm.removeItem(at: root.appendingPathComponent(name))
            }
        }
        AdHosts.shared.reloadInBackground()
        NSLog("[Kentik] списки обновлены до %@", manifest.version)
        return .updated(version: manifest.version)
    }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.badResponse(http.statusCode)
        }
    }

    static func verify(_ data: Data, entry: FilterListManifest.Entry) throws {
        try verify(data, sha256: entry.sha256, bytes: entry.bytes, file: entry.file)
    }

    static func verify(_ data: Data, sha256: String, bytes: Int?, file: String) throws {
        if let bytes, bytes != data.count { throw UpdateError.sizeMismatch(file) }
        guard sha256Hex(data) == sha256 else { throw UpdateError.checksumMismatch(file) }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

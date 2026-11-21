import WebKit

/// Загрузки через WKDownload. Файлы ложатся в Documents — их видно в приложении «Файлы»
/// (На iPhone → Kentik).
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {

    static let shared = DownloadManager()

    /// Активные загрузки (WKDownload держим сами, пока не закончится).
    private var active: [ObjectIdentifier: (download: WKDownload, file: URL?, incognito: Bool)] = [:]

    /// Файлы, скачанные из вкладок инкогнито за этот запуск (только в памяти). Пока инкогнито
    /// заперто, их имён не видно ни во всплывающих сообщениях, ни в «Загрузках».
    private var incognitoFiles: Set<String> = []

    static var directory: URL { StoragePaths.documents }

    func track(_ download: WKDownload, incognito: Bool) {
        download.delegate = self
        active[ObjectIdentifier(download)] = (download, nil, incognito)
    }

    /// Файл скачан из инкогнито, и инкогнито сейчас заперто — в списке загрузок его не показываем.
    func isHiddenByLock(_ file: URL) -> Bool {
        IncognitoLock.shared.isLocked && incognitoFiles.contains(Self.key(file))
    }

    enum ToastKind { case started, saved }

    /// Текст сообщения о загрузке. Загрузка из инкогнито при запертом инкогнито — без имени файла
    /// (сообщение показывается поверх замка).
    nonisolated static func toastText(_ kind: ToastKind, fileName: String, hideName: Bool) -> String {
        switch kind {
        case .started: return hideName ? "Загрузка началась" : "Загрузка: \(fileName)"
        case .saved: return hideName ? "Файл сохранён" : "Сохранено: \(fileName)"
        }
    }

    /// Один и тот же файл может прийти как /var/… и как /private/var/…; самого файла ещё
    /// (или уже) может не быть — сводим к одному виду только папку.
    private static func key(_ file: URL) -> String {
        file.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(file.lastPathComponent).standardizedFileURL.path
    }

    private func hidesName(incognito: Bool) -> Bool {
        incognito && IncognitoLock.shared.isLocked
    }

    /// Свободное имя файла: «file.pdf», «file (2).pdf», …
    nonisolated static func uniqueURL(in directory: URL, for suggested: String) -> URL {
        let cleaned = suggested
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty ? "download" : cleaned
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }

    // MARK: - WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = Self.uniqueURL(in: dir, for: suggestedFilename)
        let incognito = active[ObjectIdentifier(download)]?.incognito ?? false
        active[ObjectIdentifier(download)] = (download, file, incognito)
        if incognito { incognitoFiles.insert(Self.key(file)) }
        let text = Self.toastText(.started, fileName: file.lastPathComponent, hideName: hidesName(incognito: incognito))
        BrowserUI.host?.showToast(text, symbol: "arrow.down.circle")
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let entry = active.removeValue(forKey: ObjectIdentifier(download))
        let name = entry?.file?.lastPathComponent ?? "файл"
        let text = Self.toastText(.saved, fileName: name, hideName: hidesName(incognito: entry?.incognito ?? false))
        BrowserUI.host?.showToast(text, symbol: "checkmark.circle")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let entry = active.removeValue(forKey: ObjectIdentifier(download))
        if let file = entry?.file {
            incognitoFiles.remove(Self.key(file))
            try? FileManager.default.removeItem(at: file)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        BrowserUI.host?.showToast("Загрузка не удалась", symbol: "exclamationmark.triangle")
    }
}

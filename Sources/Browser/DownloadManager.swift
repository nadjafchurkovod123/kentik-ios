import WebKit

/// Загрузки через WKDownload. Файлы ложатся в Documents — их видно в приложении «Файлы»
/// (На iPhone → Kentik).
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {

    static let shared = DownloadManager()

    /// Активные загрузки (WKDownload держим сами, пока не закончится).
    private var active: [ObjectIdentifier: (download: WKDownload, file: URL?)] = [:]

    static var directory: URL { StoragePaths.documents }

    func track(_ download: WKDownload) {
        download.delegate = self
        active[ObjectIdentifier(download)] = (download, nil)
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
        active[ObjectIdentifier(download)] = (download, file)
        BrowserUI.host?.showToast("Загрузка: \(file.lastPathComponent)", symbol: "arrow.down.circle")
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let entry = active.removeValue(forKey: ObjectIdentifier(download))
        let name = entry?.file?.lastPathComponent ?? "файл"
        BrowserUI.host?.showToast("Сохранено: \(name)", symbol: "checkmark.circle")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let entry = active.removeValue(forKey: ObjectIdentifier(download))
        if let file = entry?.file { try? FileManager.default.removeItem(at: file) }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        BrowserUI.host?.showToast("Загрузка не удалась", symbol: "exclamationmark.triangle")
    }
}

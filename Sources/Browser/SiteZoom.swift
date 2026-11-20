import Foundation

/// Масштаб страниц по сайтам (WKWebView.pageZoom). Для обычных вкладок запоминается в
/// UserDefaults, для инкогнито — только в памяти до конца сессии.
@MainActor
final class SiteZoom {

    static let shared = SiteZoom()

    static let steps: [Double] = [0.5, 0.67, 0.75, 0.85, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    private let defaults: UserDefaults
    private let key = "site.zoom"
    private var incognitoZoom: [String: Double] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var stored: [String: Double] {
        get { defaults.dictionary(forKey: key) as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: key) }
    }

    func zoom(for host: String?, incognito: Bool) -> Double {
        let h = displayHost(host)
        guard !h.isEmpty else { return 1 }
        if incognito, let value = incognitoZoom[h] { return value }
        return stored[h] ?? 1
    }

    func setZoom(_ zoom: Double, for host: String?, incognito: Bool) {
        let h = displayHost(host)
        guard !h.isEmpty else { return }
        if incognito {
            incognitoZoom[h] = zoom
            return
        }
        var all = stored
        if abs(zoom - 1) < 0.001 { all.removeValue(forKey: h) } else { all[h] = zoom }
        stored = all
    }

    /// Следующий шаг масштаба вверх/вниз.
    static func step(from zoom: Double, up: Bool) -> Double {
        if up { return steps.first { $0 > zoom + 0.001 } ?? steps.last! }
        return steps.last { $0 < zoom - 0.001 } ?? steps.first!
    }

    func resetAll() {
        defaults.removeObject(forKey: key)
        incognitoZoom.removeAll()
    }

    /// Сессия инкогнито закончилась — забыть её масштабы.
    func resetIncognito() {
        incognitoZoom.removeAll()
    }
}

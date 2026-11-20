import Foundation

/// Плитка домашнего экрана.
struct HomeTile: Codable, Equatable {
    var url: URL
    var title: String
    var pinned: Bool = false

    var host: String { displayHost(url.host) }
}

/// Закреплённые плитки и скрытые сайты. Частые сайты берутся из истории обычных вкладок.
@MainActor
final class TileStore {

    static let shared = TileStore()

    static let maxTiles = 8

    private let defaults: UserDefaults
    private let history: HistoryStore

    private enum Key {
        static let pinned = "home.pinned"
        static let hidden = "home.hidden"
    }

    init(defaults: UserDefaults = .standard, history: HistoryStore? = nil) {
        self.defaults = defaults
        self.history = history ?? .shared
    }

    private(set) var pinned: [HomeTile] {
        get {
            guard let data = defaults.data(forKey: Key.pinned) else { return [] }
            return (try? JSONDecoder().decode([HomeTile].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.pinned) }
    }

    private(set) var hiddenHosts: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.hidden) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.hidden) }
    }

    /// Плитки для показа: закреплённые, потом частые (без скрытых и повторов).
    func tiles() -> [HomeTile] {
        let pins = pinned
        var result = pins.map { HomeTile(url: $0.url, title: $0.title, pinned: true) }
        let used = Set(pins.map(\.host)).union(hiddenHosts)
        let room = max(0, Self.maxTiles - result.count)
        for entry in history.topSites(limit: room, excludingHosts: used) {
            result.append(HomeTile(url: entry.url, title: entry.host))
        }
        return result
    }

    func pin(_ tile: HomeTile) {
        var pins = pinned
        guard !pins.contains(where: { $0.host == tile.host }) else { return }
        pins.append(HomeTile(url: tile.url, title: tile.title, pinned: true))
        pinned = pins
        var hidden = hiddenHosts
        hidden.remove(tile.host)
        hiddenHosts = hidden
    }

    func unpin(_ tile: HomeTile) {
        pinned = pinned.filter { $0.host != tile.host }
    }

    /// Убрать плитку: открепить и больше не показывать сайт среди частых.
    func remove(_ tile: HomeTile) {
        unpin(tile)
        var hidden = hiddenHosts
        hidden.insert(tile.host)
        hiddenHosts = hidden
    }

    func resetHidden() {
        hiddenHosts = []
    }
}

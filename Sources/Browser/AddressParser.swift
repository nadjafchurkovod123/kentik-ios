import Foundation

/// Разбирает ввод адресной строки: адрес сайта или поисковый запрос.
enum AddressParser {

    /// Поисковик по умолчанию — Google. Настройки меняют его через AppSettings.applySearchEngine().
    static var searchBase = "https://www.google.com/search"
    /// Имя параметра запроса (у Яндекса — "text").
    static var searchQueryName = "q"

    /// Схемы, которые открываем как есть.
    private static let directSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file"]

    /// Возвращает URL для загрузки или nil, если строка пустая.
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let colon = text.firstIndex(of: ":") {
            let scheme = text[..<colon].lowercased()
            if directSchemes.contains(scheme), let url = URL(string: text) {
                return url
            }
        }

        if !text.contains(where: { $0.isWhitespace }), let host = hostPart(of: text) {
            if isLocalHost(host) {
                return URL(string: "http://" + text)
            }
            if looksLikeDomain(host), let url = URL(string: "https://" + text) {
                return url
            }
        }

        return searchURL(for: text)
    }

    /// Ссылка на поиск. "+" и "&" кодируются, чтобы запрос «c++» не превратился в «c  ».
    static func searchURL(for query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#/")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: searchBase + "?" + searchQueryName + "=" + encoded)
    }

    // MARK: - Разбор хоста

    private static func hostPart(of text: String) -> String? {
        let hostAndPort = text.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? text
        let host = hostAndPort.split(separator: ":").first.map(String.init) ?? hostAndPort
        return host.isEmpty ? nil : host.lowercased()
    }

    static func isLocalHost(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || isIPv4(host)
    }

    static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), part.count <= 3 else { return false }
            return (0...255).contains(value)
        }
    }

    static func looksLikeDomain(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        guard let tld = labels.last, tld.count >= 2,
              tld.allSatisfy({ $0.isLetter }) || tld.hasPrefix("xn--") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

import Foundation

/// Манифест списков фильтров: что лежит в бандле (Filters/manifest.json) и в релизе «lists».
///
/// ```json
/// {"schema": 1, "version": "202611201230", "generated": "…",
///  "lists": [{"id": "ads", "variant": "s26", "file": "ads.s26.202611201230.json.deflate",
///             "sha256": "…", "bytes": 123, "rules": 140000}]}
/// ```
/// variant — под какую версию WebKit сконвертирован список: s26 (iOS 26+) или s16 (iOS 16.4–25).
struct FilterListManifest: Codable, Equatable {

    struct Entry: Codable, Equatable {
        let id: String
        let variant: String
        let title: String?
        let file: String
        let sha256: String
        let bytes: Int?
        let rules: Int?

        /// Идентификатор в WKContentRuleListStore. В нём часть sha256, поэтому скомпилированный
        /// список кэшируется по содержимому: новая версия — новый идентификатор, старый не трогаем,
        /// пока новая не скомпилирована целиком.
        var storeIdentifier: String {
            "\(FilterListManifest.identifierPrefix)\(id).\(variant).\(sha256.prefix(16))"
        }
    }

    enum ParseError: LocalizedError, Equatable {
        case unsupportedSchema(Int)
        case badVersion(String)
        case badEntry(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let s): return "Неизвестная схема манифеста списков: \(s)"
            case .badVersion(let v): return "Неверная версия списков: «\(v)»"
            case .badEntry(let id): return "Неверная запись списка «\(id)»"
            case .empty: return "В манифесте нет списков"
            }
        }
    }

    static let supportedSchema = 1
    static let identifierPrefix = "kentik."

    let schema: Int
    let version: String
    let generated: String?
    let lists: [Entry]

    /// Разбор и проверка: схема, версия из цифр, sha256 из 64 hex, безопасные имена файлов.
    static func parse(_ data: Data) throws -> FilterListManifest {
        let manifest = try JSONDecoder().decode(FilterListManifest.self, from: data)
        guard manifest.schema == supportedSchema else { throw ParseError.unsupportedSchema(manifest.schema) }
        guard !manifest.version.isEmpty, manifest.version.allSatisfy(\.isASCIIDigit) else {
            throw ParseError.badVersion(manifest.version)
        }
        guard !manifest.lists.isEmpty else { throw ParseError.empty }
        for entry in manifest.lists {
            let okID = !entry.id.isEmpty && entry.id.allSatisfy { $0.isASCIILowerAlnum || $0 == "-" }
            let okVariant = !entry.variant.isEmpty && entry.variant.allSatisfy(\.isASCIILowerAlnum)
            let okSHA = entry.sha256.count == 64 && entry.sha256.allSatisfy(\.isLowerHexDigit)
            let okFile = !entry.file.isEmpty && !entry.file.contains("/") && !entry.file.contains("\\")
                && !entry.file.hasPrefix(".") && !entry.file.contains("..")
            guard okID, okVariant, okSHA, okFile else { throw ParseError.badEntry(entry.id) }
        }
        return manifest
    }

    /// Вариант списков для этого устройства.
    static var deviceVariant: String {
        if #available(iOS 26, *) { return "s26" }
        return "s16"
    }

    /// Списки для варианта. На iOS 26 без s26 подходят и s16 (обратная совместимость WebKit),
    /// наоборот — нет.
    func entries(for variant: String = FilterListManifest.deviceVariant) -> [Entry] {
        let exact = lists.filter { $0.variant == variant }
        if !exact.isEmpty { return exact }
        if variant == "s26" { return lists.filter { $0.variant == "s16" } }
        return []
    }

    /// Версии — строки цифр yyyyMMddHHmm; сравниваем как числа (сначала по длине).
    static func isVersion(_ candidate: String, newerThan current: String?) -> Bool {
        guard let current, !current.isEmpty, current.allSatisfy(\.isASCIIDigit) else { return true }
        let a = candidate.drop { $0 == "0" }
        let b = current.drop { $0 == "0" }
        if a.count != b.count { return a.count > b.count }
        return a > b
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
    var isASCIILowerAlnum: Bool { isASCIIDigit || ("a"..."z").contains(self) }
    var isLowerHexDigit: Bool { isASCIIDigit || ("a"..."f").contains(self) }
}

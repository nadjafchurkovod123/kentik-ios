import Foundation

/// Встроенные списки фильтров.
///
/// TODO(adblock): здесь будут списки, собранные на CI (шаг «Сборка списков фильтров» в
/// .github/workflows/ios.yml), — JSON-правила WKContentRuleList в Resources/Filters.
enum FilterLists {

    /// Версия встроенных списков. Сборка фильтров запишет её в Info.plist (KentikFilterListsVersion).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "KentikFilterListsVersion") as? String ?? "dev"
    }

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

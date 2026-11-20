import Foundation

/// Тестовые крючки. Работают только в DEBUG-сборках, включаются аргументами запуска:
///  -KentikUITest            — чистое состояние, без онбординга;
///  -KentikTestRules         — добавить маленький тестовый список правил
///                             (блокирует URL с "/ads/" и прячет ".test-ad");
///  -KentikStartURL <url>    — открыть этот адрес при запуске.
/// В Release все флаги всегда выключены.
enum TestHooks {
#if DEBUG
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var isUITest: Bool { arguments.contains("-KentikUITest") }

    static var useTestRules: Bool { arguments.contains("-KentikTestRules") }

    static var startURL: URL? {
        guard let index = arguments.firstIndex(of: "-KentikStartURL"),
              index + 1 < arguments.count else { return nil }
        return URL(string: arguments[index + 1])
    }
#else
    static var isUITest: Bool { false }
    static var useTestRules: Bool { false }
    static var startURL: URL? { nil }
#endif

    /// Сбрасывает сохранённые настройки перед UI-тестом, чтобы каждый запуск начинался с нуля.
    static func prepareFreshStateIfNeeded() {
        guard isUITest else { return }
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }
}

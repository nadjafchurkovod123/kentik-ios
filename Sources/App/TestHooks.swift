import Foundation

/// Тестовые крючки. Работают только в DEBUG-сборках, включаются аргументами запуска:
///  -KentikUITest            — чистое состояние, без онбординга;
///  -KentikTestRules         — добавить маленький тестовый список правил
///                             (блокирует URL с "/ads/" и прячет ".test-ad");
///  -KentikStartURL <url>    — открыть этот адрес при запуске;
///  -KentikPersistSession    — в UI-тесте всё же сохранять и восстанавливать вкладки
///                             (тест восстановления сессии перезапускает приложение);
///  -KentikIncognitoFaceID   — включить «Face ID для инкогнито» (без проверки при включении);
///  -KentikFakeAuth          — вместо Face ID показывать тестовый запрос «Разрешить / Отменить»
///                             (в симуляторе нет Face ID и кода-пароля, проверка проходит сама).
/// В Release все флаги всегда выключены.
enum TestHooks {
#if DEBUG
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var isUITest: Bool { arguments.contains("-KentikUITest") }

    static var useTestRules: Bool { arguments.contains("-KentikTestRules") }

    static var persistSession: Bool { arguments.contains("-KentikPersistSession") }

    static var incognitoFaceID: Bool { arguments.contains("-KentikIncognitoFaceID") }

    static var fakeAuth: Bool { arguments.contains("-KentikFakeAuth") }

    static var startURL: URL? {
        guard let index = arguments.firstIndex(of: "-KentikStartURL"),
              index + 1 < arguments.count else { return nil }
        return URL(string: arguments[index + 1])
    }
#else
    static var isUITest: Bool { false }
    static var useTestRules: Bool { false }
    static var persistSession: Bool { false }
    static var incognitoFaceID: Bool { false }
    static var fakeAuth: Bool { false }
    static var startURL: URL? { nil }
#endif

    /// Сессию (вкладки) не сохраняем и не восстанавливаем: UI-тест начинается с чистого листа,
    /// кроме теста восстановления (-KentikPersistSession).
    static var skipsSession: Bool { isUITest && !persistSession }

    /// Сбрасывает сохранённые настройки перед UI-тестом, чтобы каждый запуск начинался с нуля.
    static func prepareFreshStateIfNeeded() {
        guard isUITest else { return }
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }
}

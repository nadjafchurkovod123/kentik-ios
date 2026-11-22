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

    /// Опыты для диагностики (DiagProbe): без скриплетов защиты Guard / без списков
    /// блокировщика / веб-вью на Auto Layout, как в 1.0.1 (для сравнения).
    static var noGuard: Bool { arguments.contains("-KentikNoGuard") }
    static var noBlocker: Bool { arguments.contains("-KentikNoBlocker") }
    static var webViewAutoLayout: Bool { arguments.contains("-KentikWebViewAutoLayout") }
    /// Без скриптлетов AdGuard (сравнение «как в 1.0.1» на YouTube).
    static var noAdGuard: Bool { arguments.contains("-KentikNoAdGuard") }

    /// -KentikIncognitoGrace <секунды> — сколько можно пробыть на обычных вкладках, не запирая
    /// инкогнито (по умолчанию 30 с; тестам нужно короче).
    static var incognitoGrace: TimeInterval? {
        guard let index = arguments.firstIndex(of: "-KentikIncognitoGrace"), index + 1 < arguments.count else { return nil }
        return TimeInterval(arguments[index + 1])
    }

    /// -KentikIncognitoFaceIDOff — «Face ID для инкогнито» выключено (как будто пользователь
    /// выключил сам).
    static var incognitoFaceIDOff: Bool { arguments.contains("-KentikIncognitoFaceIDOff") }

    /// -KentikFreshHistory — в UI-тесте с -KentikPersistSession начать с пустой истории
    /// (дальше она пишется на диск, как у пользователя).
    static var freshHistory: Bool { arguments.contains("-KentikFreshHistory") }

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
    static var noGuard: Bool { false }
    static var noBlocker: Bool { false }
    static var webViewAutoLayout: Bool { false }
    static var noAdGuard: Bool { false }
    static var incognitoGrace: TimeInterval? { nil }
    static var incognitoFaceIDOff: Bool { false }
    static var freshHistory: Bool { false }
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

import UIKit

/// Цвета Kentik — те же, что в десктопной версии (--frame, --bar, --tab, --field, --vio):
/// тёмно-серые поверхности и фиолетовый акцент. Инкогнито — фиолетовый оттенок интерфейса.
enum Theme {
    // Обычный режим.
    /// Фон страницы и окна (--frame).
    static let background = UIColor(hex: 0x1C1B22)
    /// Панели (--bar).
    static let bar = UIColor(hex: 0x2B2A33)
    /// Поле ввода на панели.
    static let field = UIColor(hex: 0x1C1B22)
    /// Карточки, плитки (--tab).
    static let surface = UIColor(hex: 0x42414D)
    /// Разделители (--line).
    static let line = UIColor(hex: 0x393842)

    // Инкогнито.
    static let incognitoBackground = UIColor(hex: 0x1A0F2E)
    static let barIncognito = UIColor(hex: 0x2E1754)
    static let fieldIncognito = UIColor(hex: 0x1C0B36)
    static let surfaceIncognito = UIColor(hex: 0x4B2A85)
    static let lineIncognito = UIColor(hex: 0x4A2D63)

    /// Фиолетовый акцент (--vio / --link).
    static let violet = UIColor(hex: 0xA78BFA)
    /// Кольцо выделения (--ring).
    static let ring = UIColor(hex: 0x8B7CF6)
    static let accent = UIColor(hex: 0xC08CF0)
    static let text = UIColor(hex: 0xFBFBFE)
    static let dim = UIColor(hex: 0xBFBFC9)
    static let faint = UIColor(hex: 0x8F8F9D)
    static let ok = UIColor(hex: 0x54D98C)
    static let warn = UIColor(hex: 0xFFD567)
    static let bad = UIColor(hex: 0xFF7A8A)

    /// Длительности анимаций: короткие и дешёвые (только transform/alpha/цвет).
    static let fast: TimeInterval = 0.12
    static let mid: TimeInterval = 0.2
    static let slow: TimeInterval = 0.3
}

/// Набор цветов панелей для режима (обычный / инкогнито).
struct ChromePalette {
    let background: UIColor
    let bar: UIColor
    let field: UIColor
    let surface: UIColor
    let line: UIColor

    static let normal = ChromePalette(
        background: Theme.background, bar: Theme.bar, field: Theme.field,
        surface: Theme.surface, line: Theme.line
    )
    static let incognito = ChromePalette(
        background: Theme.incognitoBackground, bar: Theme.barIncognito, field: Theme.fieldIncognito,
        surface: Theme.surfaceIncognito, line: Theme.lineIncognito
    )

    static func forIncognito(_ incognito: Bool) -> ChromePalette {
        incognito ? .incognito : .normal
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Светлый ли цвет (для выбора стиля строки состояния над цветом темы сайта).
    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6
    }
}

/// Отложенный вызов на главном потоке.
@MainActor
func runAfter(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        work()
    }
}

/// Хост для показа: без «www.» и в нижнем регистре.
func displayHost(_ host: String?) -> String {
    guard let host, !host.isEmpty else { return "" }
    let lower = host.lowercased()
    return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
}

// MARK: - Шрифты с Dynamic Type

extension Theme {
    /// Шрифт интерфейса браузера с Dynamic Type: растёт вместе с «Крупным текстом» в настройках
    /// iPhone, но не больше `maximum` (панели не резиновые). Метке нужно
    /// `adjustsFontForContentSizeCategory = true`, чтобы она обновлялась на лету.
    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular, style: UIFont.TextStyle = .body,
                     maximum: CGFloat? = nil) -> UIFont {
        scaled(.systemFont(ofSize: size, weight: weight), style: style, maximum: maximum)
    }

    /// Цифры одинаковой ширины (счётчики) с Dynamic Type.
    static func digits(_ size: CGFloat, _ weight: UIFont.Weight = .bold, style: UIFont.TextStyle = .body,
                       maximum: CGFloat? = nil) -> UIFont {
        scaled(.monospacedDigitSystemFont(ofSize: size, weight: weight), style: style, maximum: maximum)
    }

    private static func scaled(_ font: UIFont, style: UIFont.TextStyle, maximum: CGFloat?) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: style)
        if let maximum { return metrics.scaledFont(for: font, maximumPointSize: maximum) }
        return metrics.scaledFont(for: font)
    }
}

// MARK: - Русские числительные

/// Форма слова после числа: 1 окно, 2 окна, 5 окон (11–14 — как 5).
enum RussianPlural {
    static func form(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n = abs(n) % 100
        if (11...14).contains(n) { return many }
        switch n % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }

    static func days(_ n: Int) -> String { form(n, "день", "дня", "дней") }
}

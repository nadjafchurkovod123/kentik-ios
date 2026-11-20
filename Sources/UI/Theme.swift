import UIKit

/// Цвета Kentik — те же, что в десктопной версии: тёмный фиолетовый интерфейс,
/// акцент var(--vio).
enum Theme {
    static let background = UIColor(hex: 0x0F0A17)
    static let bar = UIColor(hex: 0x1E0B36)
    static let barIncognito = UIColor(hex: 0x2A1150)
    static let field = UIColor(hex: 0x170828)
    /// Фиолетовый акцент (--vio / --link).
    static let violet = UIColor(hex: 0xA78BFA)
    static let accent = UIColor(hex: 0xC08CF0)
    static let text = UIColor(hex: 0xFBFBFE)
    static let dim = UIColor(hex: 0xBFBFC9)
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
}

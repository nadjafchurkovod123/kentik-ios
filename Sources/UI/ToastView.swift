import UIKit

/// Короткое уведомление-«капсула» над нижней панелью: «Открыто в фоне» и т. п.
final class ToastView: UIView {

    private let label = UILabel()
    private let icon = UIImageView()

    init(text: String, symbol: String?) {
        super.init(frame: .zero)
        backgroundColor = UIColor(hex: 0x42414D, alpha: 0.97)
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Theme.violet.withAlphaComponent(0.35).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)
        isAccessibilityElement = true
        accessibilityIdentifier = "toast"
        accessibilityLabel = text
        isUserInteractionEnabled = false

        label.text = text
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = Theme.text
        label.numberOfLines = 2
        icon.image = symbol.flatMap { UIImage(systemName: $0) }
        icon.tintColor = Theme.violet
        icon.preferredSymbolConfiguration = .init(pointSize: 15, weight: .semibold)
        icon.isHidden = symbol == nil
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    /// Показать над `anchor` (верхний край нижней панели) и спрятать через `duration`.
    @MainActor
    static func show(_ text: String, symbol: String?, in container: UIView, above anchor: NSLayoutYAxisAnchor,
                     duration: TimeInterval = 1.8) {
        container.subviews.compactMap { $0 as? ToastView }.forEach { $0.removeFromSuperview() }
        let toast = ToastView(text: text, symbol: symbol)
        toast.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: anchor, constant: -12),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])
        container.layoutIfNeeded()
        toast.alpha = 0
        toast.transform = CGAffineTransform(translationX: 0, y: 12).scaledBy(x: 0.96, y: 0.96)
        UIView.animate(withDuration: Theme.mid, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
            toast.alpha = 1
            toast.transform = .identity
        }
        UIAccessibility.post(notification: .announcement, argument: text)
        runAfter(duration) { [weak toast] in
            guard let toast else { return }
            UIView.animate(withDuration: Theme.mid, animations: {
                toast.alpha = 0
                toast.transform = CGAffineTransform(translationX: 0, y: 8)
            }, completion: { _ in toast.removeFromSuperview() })
        }
    }
}

import UIKit

/// Плашка «Готовлю блокировщик рекламы…» внизу экрана, пока списки компилируются
/// (обычно только при первом запуске). Сама подписывается на ContentBlocker и сама
/// встраивается в главное окно — снаружи достаточно вызвать `BlockerStatusBanner.start()`.
@MainActor
final class BlockerStatusBanner: UIView {

    private static var shared: BlockerStatusBanner?

    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var generation = 0

    /// Начать следить за статусом блокировщика (повторные вызовы ничего не делают).
    static func start() {
        guard shared == nil else { return }
        let banner = BlockerStatusBanner()
        shared = banner
        NotificationCenter.default.addObserver(
            banner, selector: #selector(statusChanged), name: .contentBlockerStatusChanged, object: nil
        )
        banner.statusChanged()
    }

    private init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "blockerStatus"
        backgroundColor = Theme.bar.withAlphaComponent(0.96)
        layer.cornerRadius = 18
        layer.borderWidth = 1
        layer.borderColor = Theme.violet.withAlphaComponent(0.45).cgColor
        alpha = 0
        isUserInteractionEnabled = false

        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = Theme.text
        label.numberOfLines = 2
        spinner.color = Theme.violet
        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    @objc private func statusChanged() {
        let text = ContentBlocker.shared.statusText
        generation += 1
        guard let text else {
            UIView.animate(withDuration: 0.25, animations: { self.alpha = 0 }) { _ in
                if ContentBlocker.shared.statusText == nil { self.removeFromSuperview() }
            }
            return
        }
        label.text = text
        accessibilityLabel = text
        if superview != nil { return }
        // Короткую подготовку (из кэша) не показываем — плашка только если это надолго.
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.generation == expected || ContentBlocker.shared.statusText != nil else { return }
            self.attach()
        }
    }

    private func attach() {
        guard ContentBlocker.shared.statusText != nil, superview == nil, let window = Self.keyWindow() else { return }
        // В вид главного экрана, а не в окно: открытые шторки (щит, настройки) лежат выше и
        // плашку закрывают — шторка щита сама показывает ход подготовки.
        let container: UIView = window.rootViewController?.view ?? window
        translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: container.centerXAnchor),
            leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            // Над нижней панелью (адресная строка + кнопки) — не закрывает их.
            bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -124),
        ])
        UIView.animate(withDuration: 0.25) { self.alpha = 1 }
    }

    private static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}

import UIKit

/// Ненавязчивая плашка внизу страницы: «Всплывающее окно заблокировано · Открыть».
///
/// Показывается, когда защита гасит окно или рекламный переход. «Открыть» — явный выбор
/// пользователя: окно открывается в новой вкладке, переход — в этой. Плашка живёт поверх
/// веб-вью своей вкладки (и уходит вместе с ней при переключении), сама прячется через
/// несколько секунд; повторные блокировки обновляют её, а не плодят новые.
final class BlockedNoticeBar: UIView {

    enum Kind {
        case popup
        case redirect

        var text: String {
            switch self {
            case .popup: return "Всплывающее окно заблокировано"
            case .redirect: return "Переход на рекламу заблокирован"
            }
        }
    }

    static let visibleSeconds: TimeInterval = 6

    private weak var tab: Tab?
    private var kind: Kind = .popup
    private var url: URL?
    private var count = 0
    private var hideWork: DispatchWorkItem?

    private let icon = UIImageView(image: UIImage(systemName: "hand.raised.slash.fill"))
    private let label = UILabel()
    private let openButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    /// Показать (или обновить) плашку на веб-вью вкладки.
    @MainActor
    static func show(_ kind: Kind, url: URL?, on tab: Tab) {
        guard let webView = tab.webView else { return }
        let bar = webView.subviews.compactMap { $0 as? BlockedNoticeBar }.first ?? {
            let bar = BlockedNoticeBar()
            bar.attach(to: webView)
            return bar
        }()
        bar.tab = tab
        bar.update(kind: kind, url: url)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    private func build() {
        accessibilityIdentifier = "popupBlockedBar"
        backgroundColor = Theme.bar.withAlphaComponent(0.97)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Theme.violet.withAlphaComponent(0.35).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 6)

        icon.tintColor = Theme.violet
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.textColor = Theme.text
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        label.numberOfLines = 1
        label.accessibilityIdentifier = "popupBlockedText"

        var open = UIButton.Configuration.plain()
        open.title = "Открыть"
        open.baseForegroundColor = Theme.violet
        open.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 6)
        open.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 15, weight: .semibold)
            return attributes
        }
        openButton.configuration = open
        openButton.accessibilityIdentifier = "popupBlockedOpen"
        openButton.setContentHuggingPriority(.required, for: .horizontal)
        openButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        openButton.addTarget(self, action: #selector(openTapped), for: .touchUpInside)

        var close = UIButton.Configuration.plain()
        close.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        close.baseForegroundColor = Theme.dim
        close.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        closeButton.configuration = close
        closeButton.accessibilityIdentifier = "popupBlockedClose"
        closeButton.accessibilityLabel = "Закрыть"
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, label, openButton, closeButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
    }

    private func attach(to webView: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        webView.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: webView.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            trailingAnchor.constraint(equalTo: webView.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            bottomAnchor.constraint(equalTo: webView.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: 24)
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    private func update(kind: Kind, url: URL?) {
        if self.kind != kind { count = 0 }
        self.kind = kind
        self.url = url ?? self.url
        count += 1
        label.text = count > 1 ? "\(kind.text) · \(count)" : kind.text
        openButton.isHidden = self.url == nil
        accessibilityLabel = label.text
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleSeconds, execute: work)
    }

    private func dismiss() {
        hideWork?.cancel()
        UIView.animate(withDuration: 0.2, animations: {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: 16)
        }, completion: { _ in
            self.removeFromSuperview()
        })
    }

    @objc private func openTapped() {
        guard let tab, let url else { return dismiss() }
        dismiss()
        switch kind {
        case .popup:
            if let manager = tab.manager {
                manager.addTab(url: url, incognito: tab.isIncognito, select: true, opener: tab)
            } else {
                tab.load(url)
            }
        case .redirect:
            tab.load(url)
        }
    }

    @objc private func closeTapped() {
        dismiss()
    }
}

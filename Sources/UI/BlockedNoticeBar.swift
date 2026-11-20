import UIKit

/// Ненавязчивая плашка вверху страницы: «Всплывающее окно заблокировано · Открыть».
///
/// Показывается, когда защита гасит окно или рекламный переход, — один раз на страницу:
/// попандеры срабатывают на каждое касание плеера, и дальше счёт идёт только в значке щита.
/// Стоит вверху, подальше от большого пальца (внизу — адресная строка и уведомления), и сама
/// прячется через несколько секунд; повторные блокировки, пока она на экране, только
/// обновляют счётчик и не продлевают её. «Открыть» — явный выбор пользователя: окно
/// открывается в ФОНОВОЙ вкладке (рекламная страница не выскакивает на экран), переход —
/// в этой. Плашка живёт поверх веб-вью своей вкладки и уходит вместе с ней.
final class BlockedNoticeBar: UIView {

    enum Kind {
        case popup
        /// Переход на хост из списка рекламных.
        case redirect
        /// Скрипт страницы уводил вкладку на другой сайт.
        case siteRedirect

        var text: String {
            switch self {
            case .popup: return "Всплывающее окно заблокировано"
            case .redirect: return "Переход на рекламу заблокирован"
            case .siteRedirect: return "Переход на другой сайт заблокирован"
            }
        }
    }

    /// Сколько плашка висит. В UI-тестах дольше: медленный симулятор не должен успевать
    /// её прятать, пока тест ищет кнопку.
    static var visibleSeconds: TimeInterval { TestHooks.isUITest ? 30 : 8 }

    private weak var tab: Tab?
    private var kind: Kind = .popup
    private var url: URL?
    private var count = 0
    private var hideWork: DispatchWorkItem?
    private var isDismissing = false

    private let icon = UIImageView(image: UIImage(systemName: "hand.raised.slash.fill"))
    private let label = UILabel()
    private let openButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    /// Показать (или обновить) плашку на веб-вью вкладки.
    @MainActor
    static func show(_ kind: Kind, url: URL?, on tab: Tab) {
        guard let webView = tab.webView else { return }
        if let bar = webView.subviews.compactMap({ $0 as? BlockedNoticeBar }).first(where: { !$0.isDismissing }) {
            bar.tab = tab
            bar.update(kind: kind, url: url)
            return
        }
        // На этой странице плашку уже показывали — дальше только значок щита.
        let page = pageKey(webView.url)
        guard tab.noticeShownForPage != page else { return }
        tab.noticeShownForPage = page
        let bar = BlockedNoticeBar()
        bar.attach(to: webView)
        bar.tab = tab
        bar.update(kind: kind, url: url)
        bar.scheduleHide()
        UIAccessibility.post(notification: .announcement, argument: bar.label.text)
    }

    /// Страница без #фрагмента (плашка — одна на страницу).
    static func pageKey(_ url: URL?) -> String {
        guard let url else { return "" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
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
        label.font = Theme.font(14, .medium, style: .subheadline, maximum: 18)
        label.adjustsFontForContentSizeCategory = true
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
            attributes.font = Theme.font(15, .semibold, style: .subheadline, maximum: 19)
            return attributes
        }
        openButton.configuration = open
        openButton.accessibilityIdentifier = "popupBlockedOpen"
        openButton.accessibilityHint = "Открывает заблокированное в фоновой вкладке"
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
            topAnchor.constraint(equalTo: webView.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: -24)
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
        openButton.accessibilityHint = kind == .popup
            ? "Открывает окно в фоновой вкладке" : "Переходит по заблокированному адресу"
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleSeconds, execute: work)
    }

    private func dismiss() {
        hideWork?.cancel()
        isDismissing = true
        UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: -16)
        }, completion: { _ in
            self.removeFromSuperview()
        })
    }

    @objc private func openTapped() {
        guard let tab, let url else { return dismiss() }
        dismiss()
        switch kind {
        case .popup:
            // В фоне: если это всё-таки реклама, она не выскочит поверх страницы.
            if let manager = tab.manager {
                manager.addTab(url: url, incognito: tab.isIncognito, select: false, opener: tab)
                BrowserUI.host?.showToast("Окно открыто в фоновой вкладке", symbol: "square.on.square")
            } else {
                tab.load(url)
            }
        case .redirect, .siteRedirect:
            tab.load(url)
        }
    }

    @objc private func closeTapped() {
        dismiss()
    }
}

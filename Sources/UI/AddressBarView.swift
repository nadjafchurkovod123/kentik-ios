import UIKit

/// Состояние щита для значка.
enum ShieldState {
    case on, siteOff, off

    var symbol: String {
        switch self {
        case .on: return "checkmark.shield.fill"
        case .siteOff: return "shield.slash"
        case .off: return "shield.slash.fill"
        }
    }

    var color: UIColor {
        switch self {
        case .on: return Theme.violet
        case .siteOff: return Theme.warn
        case .off: return Theme.bad
        }
    }

    var accessibilityValue: String {
        switch self {
        case .on: return "включена"
        case .siteOff: return "выключена на сайте"
        case .off: return "выключена"
        }
    }
}

/// Строка адреса: «таблетка» с полем ввода, заголовком, полосой загрузки и кнопкой
/// обновления, справа — кнопка щита (или «Отмена» при вводе).
/// Стоит внизу (по умолчанию) или вверху — решает BrowserViewController.
final class AddressBarView: UIView {

    let pill = UIView()
    let titleLabel = UILabel()
    let textField = UITextField()
    let progressView = UIProgressView(progressViewStyle: .bar)
    let reloadButton = UIButton(type: .system)
    let shieldButton = UIButton(type: .system)
    let cancelButton = UIButton(type: .system)
    private let iconView = UIImageView()
    /// Кружок с градиентом под значком «глаз» в инкогнито — как значок приватного окна на десктопе.
    private let incognitoBadge = GradientView()
    /// Значок безопасности (замок / предупреждение) рядом с меткой инкогнито.
    private let securityIcon = UIImageView()
    private var securityWidth: NSLayoutConstraint!
    private var securitySpacing: NSLayoutConstraint!
    private let shieldBadge = UILabel()

    private var editingConstraints: [NSLayoutConstraint] = []
    private var pageConstraints: [NSLayoutConstraint] = []
    private var plainConstraints: [NSLayoutConstraint] = []
    private var pillTrailingToShield: NSLayoutConstraint!
    private var pillTrailingToCancel: NSLayoutConstraint!

    private(set) var isEditingAddress = false
    private var palette = ChromePalette.normal
    private var hasPage = false

    static let height: CGFloat = 58

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        pill.layer.cornerRadius = 15
        pill.layer.cornerCurve = .continuous
        pill.clipsToBounds = true
        pill.layer.borderWidth = 1

        titleLabel.font = Theme.font(11, .medium, style: .caption2, maximum: 13)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.dim
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityIdentifier = "pageTitle"

        textField.textColor = Theme.text
        textField.tintColor = Theme.violet
        textField.font = Theme.font(16, style: .body, maximum: 20)
        textField.adjustsFontForContentSizeCategory = true
        textField.keyboardType = .webSearch
        textField.returnKeyType = .go
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartQuotesType = .no
        textField.smartDashesType = .no
        textField.clearButtonMode = .whileEditing
        textField.textContentType = .URL
        textField.keyboardAppearance = .dark
        textField.accessibilityIdentifier = "addressBar"

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = Theme.dim
        iconView.preferredSymbolConfiguration = .init(pointSize: 14, weight: .semibold)
        securityIcon.contentMode = .scaleAspectFit
        securityIcon.preferredSymbolConfiguration = .init(pointSize: 11, weight: .semibold)
        securityIcon.isHidden = true

        reloadButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        reloadButton.tintColor = Theme.dim
        reloadButton.accessibilityIdentifier = "reloadButton"
        reloadButton.accessibilityLabel = "Обновить"
        reloadButton.setPreferredSymbolConfiguration(.init(pointSize: 15, weight: .semibold), forImageIn: .normal)

        progressView.progressTintColor = Theme.violet
        progressView.trackTintColor = .clear
        progressView.accessibilityIdentifier = "progressBar"
        progressView.isHidden = true
        progressView.isUserInteractionEnabled = false

        shieldButton.accessibilityIdentifier = "shieldButton"
        shieldButton.accessibilityLabel = "Блокировка рекламы"
        shieldButton.setPreferredSymbolConfiguration(.init(pointSize: 20, weight: .semibold), forImageIn: .normal)

        shieldBadge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        shieldBadge.textColor = Theme.background
        shieldBadge.backgroundColor = Theme.violet
        shieldBadge.textAlignment = .center
        shieldBadge.layer.cornerRadius = 7.5
        shieldBadge.clipsToBounds = true
        shieldBadge.isHidden = true
        shieldBadge.isUserInteractionEnabled = false
        shieldBadge.isAccessibilityElement = false

        cancelButton.setTitle("Отмена", for: .normal)
        cancelButton.titleLabel?.font = Theme.font(16, .medium, style: .body, maximum: 20)
        cancelButton.titleLabel?.adjustsFontForContentSizeCategory = true
        cancelButton.tintColor = Theme.violet
        cancelButton.accessibilityIdentifier = "cancelEditing"
        cancelButton.alpha = 0
        cancelButton.isHidden = true

        addSubview(pill)
        addSubview(shieldButton)
        addSubview(cancelButton)
        shieldButton.addSubview(shieldBadge)
        incognitoBadge.setHorizontal(Theme.incognitoGradient)
        incognitoBadge.layer.cornerRadius = 13
        incognitoBadge.clipsToBounds = true
        incognitoBadge.isHidden = true
        incognitoBadge.isUserInteractionEnabled = false
        [incognitoBadge, iconView, securityIcon, titleLabel, textField, reloadButton, progressView].forEach { pill.addSubview($0) }
        [pill, shieldButton, cancelButton, shieldBadge, incognitoBadge, iconView, securityIcon, titleLabel, textField, reloadButton, progressView]
            .forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        securityWidth = securityIcon.widthAnchor.constraint(equalToConstant: 0)
        securitySpacing = securityIcon.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 0)

        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        pillTrailingToShield = pill.trailingAnchor.constraint(equalTo: shieldButton.leadingAnchor, constant: -4)
        pillTrailingToCancel = pill.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -10)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 46),
            pillTrailingToShield,

            shieldButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            shieldButton.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            shieldButton.widthAnchor.constraint(equalToConstant: 46),
            shieldButton.heightAnchor.constraint(equalToConstant: 46),

            shieldBadge.topAnchor.constraint(equalTo: shieldButton.topAnchor, constant: 4),
            shieldBadge.trailingAnchor.constraint(equalTo: shieldButton.trailingAnchor, constant: -2),
            shieldBadge.heightAnchor.constraint(equalToConstant: 15),
            shieldBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 15),

            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            cancelButton.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            iconView.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            incognitoBadge.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            incognitoBadge.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            incognitoBadge.widthAnchor.constraint(equalToConstant: 26),
            incognitoBadge.heightAnchor.constraint(equalToConstant: 26),

            reloadButton.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            reloadButton.topAnchor.constraint(equalTo: pill.topAnchor),
            reloadButton.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 42),

            securitySpacing,
            securityWidth,
            securityIcon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            securityIcon.heightAnchor.constraint(equalToConstant: 14),
            textField.leadingAnchor.constraint(equalTo: securityIcon.trailingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -2),

            titleLabel.topAnchor.constraint(equalTo: pill.topAnchor, constant: 5),
            titleLabel.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: textField.trailingAnchor),

            progressView.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            progressView.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
            progressView.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -1),
            progressView.heightAnchor.constraint(equalToConstant: 2.5),
        ])

        // Три раскладки поля: ввод (во всю высоту), страница (заголовок + домен), пусто.
        editingConstraints = [
            textField.topAnchor.constraint(equalTo: pill.topAnchor),
            textField.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ]
        pageConstraints = [
            textField.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -5),
            textField.heightAnchor.constraint(equalToConstant: 21),
        ]
        plainConstraints = [
            textField.topAnchor.constraint(equalTo: pill.topAnchor),
            textField.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ]
        NSLayoutConstraint.activate(plainConstraints)

        let tap = UITapGestureRecognizer(target: self, action: #selector(pillTapped))
        pill.addGestureRecognizer(tap)

        applyPalette(.normal, incognito: false)
        applyLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    @objc private func pillTapped() {
        if !textField.isFirstResponder { textField.becomeFirstResponder() }
    }

    // MARK: - Состояние

    func applyPalette(_ palette: ChromePalette, incognito: Bool) {
        self.palette = palette
        pill.backgroundColor = palette.field
        pill.layer.borderColor = (incognito ? Theme.lineIncognito : palette.line).cgColor
        pill.layer.borderWidth = incognito ? 1.5 : 1
        incognitoBadge.isHidden = !incognito
        pill.accessibilityIdentifier = incognito ? "incognitoAddressBar" : "addressPill"
        let placeholder = incognito ? "Инкогнито: поиск или адрес" : "Поиск или адрес"
        textField.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: incognito ? Theme.violet.withAlphaComponent(0.75) : Theme.faint]
        )
    }

    /// Обновить показ: адрес, заголовок, значок слева.
    func update(url: URL?, title: String, incognito: Bool) {
        hasPage = url != nil
        if !textField.isFirstResponder {
            textField.text = Self.displayText(for: url)
        }
        titleLabel.text = title
        let symbol: String
        var tint = Theme.dim
        // В инкогнито метка «глаз» стоит всегда, а замок / предупреждение http — рядом с ней.
        var security: (symbol: String, tint: UIColor)?
        let https = url?.scheme?.lowercased() == "https"
        if isEditingAddress || url == nil {
            symbol = incognito ? "eye.slash" : "magnifyingglass"
            if incognito { tint = .white }
        } else if incognito {
            symbol = "eye.slash"
            tint = .white
            security = https ? ("lock.fill", Theme.dim) : ("exclamationmark.triangle.fill", Theme.warn)
        } else if https {
            symbol = "lock.fill"
        } else {
            symbol = "exclamationmark.triangle.fill"
            tint = Theme.warn
        }
        iconView.image = UIImage(systemName: symbol)
        iconView.tintColor = tint
        iconView.isAccessibilityElement = incognito
        iconView.accessibilityLabel = incognito ? "Инкогнито" : nil
        iconView.accessibilityIdentifier = incognito ? "incognitoBadge" : nil
        iconView.preferredSymbolConfiguration = .init(pointSize: incognito ? 12 : 14, weight: .semibold)
        securityIcon.image = security.flatMap { UIImage(systemName: $0.symbol) }
        securityIcon.tintColor = security?.tint
        securityIcon.isHidden = security == nil
        securityIcon.isAccessibilityElement = security != nil
        securityIcon.accessibilityLabel = security == nil ? nil : (https ? "Защищённое соединение" : "Незащищённое соединение")
        securityWidth.constant = security == nil ? 0 : 13
        securitySpacing.constant = security == nil ? 0 : 4
        applyLayout()
    }

    func setLoading(_ loading: Bool, progress: Double) {
        reloadButton.setImage(UIImage(systemName: loading ? "xmark" : "arrow.clockwise"), for: .normal)
        reloadButton.accessibilityLabel = loading ? "Остановить" : "Обновить"
        if loading {
            if progressView.isHidden {
                progressView.setProgress(0, animated: false)
                progressView.alpha = 1
                progressView.isHidden = false
            }
            progressView.setProgress(Float(max(progress, 0.08)), animated: true)
        } else if !progressView.isHidden {
            progressView.setProgress(1, animated: true)
            UIView.animate(withDuration: Theme.mid, delay: 0.15, options: [.beginFromCurrentState]) {
                self.progressView.alpha = 0
            } completion: { _ in
                if self.progressView.alpha == 0 {
                    self.progressView.isHidden = true
                    self.progressView.setProgress(0, animated: false)
                }
            }
        }
    }

    func setShield(_ state: ShieldState, blocked: Int) {
        shieldButton.setImage(UIImage(systemName: state.symbol), for: .normal)
        shieldButton.tintColor = state.color
        shieldButton.accessibilityValue = state.accessibilityValue
        let showBadge = state == .on && blocked > 0
        shieldBadge.isHidden = !showBadge
        shieldBadge.text = blocked > 99 ? "99+" : " \(blocked) "
    }

    /// Режим ввода: поле во всю высоту, «Отмена» вместо щита.
    func setEditing(_ editing: Bool, animated: Bool) {
        guard editing != isEditingAddress else { return }
        isEditingAddress = editing
        cancelButton.isHidden = false
        if editing {
            pillTrailingToShield.isActive = false
            pillTrailingToCancel.isActive = true
        } else {
            pillTrailingToCancel.isActive = false
            pillTrailingToShield.isActive = true
        }
        applyLayout()
        let changes = {
            self.cancelButton.alpha = editing ? 1 : 0
            self.shieldButton.alpha = editing ? 0 : 1
            self.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: Theme.mid, delay: 0, options: [.curveEaseOut, .beginFromCurrentState],
                           animations: changes) { _ in
                self.cancelButton.isHidden = !self.isEditingAddress
            }
        } else {
            changes()
            cancelButton.isHidden = !editing
        }
    }

    private var layoutKey = -1

    private func applyLayout() {
        let showTitle = !isEditingAddress && hasPage && !(titleLabel.text ?? "").isEmpty
        let key = (isEditingAddress ? 1 : 0) | (showTitle ? 2 : 0) | (hasPage ? 4 : 0)
        guard key != layoutKey else { return }
        layoutKey = key
        NSLayoutConstraint.deactivate(editingConstraints + pageConstraints + plainConstraints)
        if isEditingAddress {
            NSLayoutConstraint.activate(editingConstraints)
        } else if showTitle {
            NSLayoutConstraint.activate(pageConstraints)
        } else {
            NSLayoutConstraint.activate(plainConstraints)
        }
        titleLabel.isHidden = !showTitle
        textField.textAlignment = isEditingAddress ? .natural : .center
        // Растёт с «Крупным текстом», но в строку высотой 46 pt (под заголовком — 21 pt).
        textField.font = showTitle
            ? Theme.font(15, .semibold, style: .body, maximum: 17)
            : Theme.font(16, style: .body, maximum: 20)
        reloadButton.isHidden = isEditingAddress || !hasPage
    }

    static func displayText(for url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        if let host = url.host, !host.isEmpty { return displayHost(host) }
        return url.absoluteString
    }
}

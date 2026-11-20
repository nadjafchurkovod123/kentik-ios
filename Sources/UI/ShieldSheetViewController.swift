import UIKit

/// Компактная шторка щита, как в AdBlock: общий выключатель, выключатель для сайта,
/// счётчики заблокированного, обновление списков и переход в настройки.
final class ShieldSheetViewController: UIViewController {

    private let shield: ShieldControlling
    private weak var tab: Tab?
    private let incognito: Bool
    /// Открыть настройки (шторка к этому моменту уже закрыта).
    var onOpenSettings: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let globalSwitch = UISwitch()
    private let siteSwitch = UISwitch()
    private let siteTitle = UILabel()
    private let siteSubtitle = UILabel()
    private let popupsValue = UILabel()
    private let redirectsValue = UILabel()
    private let hiddenValue = UILabel()
    private let updateButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let versionLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var host: String? { tab?.host }

    init(shield: ShieldControlling, tab: Tab?) {
        self.shield = shield
        self.tab = tab
        self.incognito = tab?.isIncognito ?? false
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.custom(identifier: .init("shield")) { _ in 440 }, .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let palette = ChromePalette.forIncognito(incognito)
        view.backgroundColor = palette.bar
        view.accessibilityIdentifier = "shieldSheet"
        overrideUserInterfaceStyle = .dark

        // Заголовок.
        iconView.preferredSymbolConfiguration = .init(pointSize: 26, weight: .semibold)
        iconView.contentMode = .center
        let iconHolder = UIView()
        iconHolder.layer.cornerRadius = 22
        iconHolder.backgroundColor = palette.field
        iconHolder.addSubview(iconView)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Щит Kentik"
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = Theme.text
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = Theme.dim
        statusLabel.accessibilityIdentifier = "shieldStatus"
        statusLabel.numberOfLines = 1
        let titles = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        titles.axis = .vertical
        titles.spacing = 2
        let header = UIStackView(arrangedSubviews: [iconHolder, titles])
        header.spacing = 12
        header.alignment = .center

        // Переключатели.
        globalSwitch.onTintColor = Theme.violet
        globalSwitch.accessibilityIdentifier = "shieldGlobalSwitch"
        globalSwitch.addTarget(self, action: #selector(globalChanged), for: .valueChanged)
        siteSwitch.onTintColor = Theme.violet
        siteSwitch.accessibilityIdentifier = "shieldSiteSwitch"
        siteSwitch.addTarget(self, action: #selector(siteChanged), for: .valueChanged)

        let globalRow = row(symbol: "shield.lefthalf.filled", title: makeLabel("Блокировка рекламы", size: 16, weight: .semibold),
                            subtitle: makeLabel("Везде: реклама, окна, переходы", size: 12, weight: .regular, color: Theme.faint),
                            control: globalSwitch)
        siteTitle.text = "На этом сайте"
        siteTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        siteTitle.textColor = Theme.text
        siteSubtitle.font = .systemFont(ofSize: 12)
        siteSubtitle.textColor = Theme.faint
        siteSubtitle.lineBreakMode = .byTruncatingMiddle
        let siteRow = row(symbol: "globe", title: siteTitle, subtitle: siteSubtitle, control: siteSwitch)

        let divider = UIView()
        divider.backgroundColor = palette.line
        divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        let switches = UIStackView(arrangedSubviews: [globalRow, divider, siteRow])
        switches.axis = .vertical
        switches.spacing = 0
        let switchesCard = card(switches, palette: palette)

        // Счётчики.
        let stats = UIStackView(arrangedSubviews: [
            statTile(popupsValue, caption: "окон\nзаблокировано", id: "shieldPopupsCount", palette: palette),
            statTile(redirectsValue, caption: "переходов\nзаблокировано", id: "shieldRedirectsCount", palette: palette),
            statTile(hiddenValue, caption: "элементов\nскрыто", id: "shieldHiddenCount", palette: palette),
        ])
        stats.axis = .horizontal
        stats.distribution = .fillEqually
        stats.spacing = 10

        // Кнопки.
        configureButton(updateButton, title: "Обновить списки", symbol: "arrow.triangle.2.circlepath", palette: palette)
        updateButton.accessibilityIdentifier = "shieldUpdateLists"
        updateButton.addTarget(self, action: #selector(updateLists), for: .touchUpInside)
        configureButton(settingsButton, title: "Настройки", symbol: "gearshape", palette: palette)
        settingsButton.accessibilityIdentifier = "shieldSettings"
        settingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [updateButton, settingsButton])
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 10

        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = Theme.faint
        versionLabel.textAlignment = .center
        spinner.color = Theme.violet
        spinner.hidesWhenStopped = true

        let content = UIStackView(arrangedSubviews: [header, switchesCard, stats, buttons, versionLabel])
        content.axis = .vertical
        content.spacing = 16
        content.setCustomSpacing(20, after: header)
        content.setCustomSpacing(10, after: buttons)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        updateButton.addSubview(spinner)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            iconHolder.widthAnchor.constraint(equalToConstant: 44),
            iconHolder.heightAnchor.constraint(equalToConstant: 44),
            iconView.centerXAnchor.constraint(equalTo: iconHolder.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconHolder.centerYAnchor),

            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 26),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            buttons.heightAnchor.constraint(equalToConstant: 46),

            spinner.trailingAnchor.constraint(equalTo: updateButton.trailingAnchor, constant: -10),
            spinner.centerYAnchor.constraint(equalTo: updateButton.centerYAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: .shieldSettingsChanged, object: nil)
        refresh()
    }

    // MARK: - Состояние

    @objc func refresh() {
        guard isViewLoaded else { return }
        let global = shield.isEnabledGlobally
        let site = shield.isEnabled(forHost: host)
        let hostText = displayHost(host)
        let state: ShieldState = !global ? .off : (site ? .on : .siteOff)

        iconView.image = UIImage(systemName: state.symbol)
        iconView.tintColor = state.color
        switch state {
        case .on: statusLabel.text = hostText.isEmpty ? "Включена" : "Включена на \(hostText)"
        case .siteOff: statusLabel.text = "Выключена на \(hostText)"
        case .off: statusLabel.text = "Выключена везде"
        }

        globalSwitch.setOn(global, animated: true)
        siteSwitch.setOn(global && site, animated: true)
        siteSwitch.isEnabled = global && !hostText.isEmpty
        siteSubtitle.text = hostText.isEmpty ? "Откройте сайт" : hostText
        siteTitle.alpha = siteSwitch.isEnabled ? 1 : 0.5

        if let tab {
            let stats = shield.stats(for: tab)
            popupsValue.text = "\(stats.blockedPopups)"
            redirectsValue.text = "\(stats.blockedRedirects)"
            hiddenValue.text = "\(stats.hiddenElements)"
            versionLabel.text = "Списки фильтров: \(stats.listsVersion)"
        } else {
            popupsValue.text = "0"
            redirectsValue.text = "0"
            hiddenValue.text = "0"
            versionLabel.text = "Списки фильтров: \(FilterLists.version)"
        }
    }

    @objc private func globalChanged() {
        UISelectionFeedbackGenerator().selectionChanged()
        shield.isEnabledGlobally = globalSwitch.isOn
        refresh()
    }

    @objc private func siteChanged() {
        guard let host else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        shield.setEnabled(siteSwitch.isOn, forHost: host)
        refresh()
    }

    @objc private func updateLists() {
        updateButton.isEnabled = false
        spinner.startAnimating()
        shield.reloadRules { [weak self] error in
            guard let self else { return }
            self.spinner.stopAnimating()
            self.updateButton.isEnabled = true
            self.versionLabel.text = error == nil
                ? "Списки обновлены · \(FilterLists.version)"
                : "Не удалось обновить списки"
        }
    }

    @objc private func openSettings() {
        let callback = onOpenSettings
        dismiss(animated: true) { callback?() }
    }

    // MARK: - Сборка

    private func makeLabel(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor = Theme.text) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    private func row(symbol: String, title: UILabel, subtitle: UILabel, control: UIView) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = Theme.violet
        icon.preferredSymbolConfiguration = .init(pointSize: 17, weight: .semibold)
        icon.contentMode = .center
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let texts = UIStackView(arrangedSubviews: [title, subtitle])
        texts.axis = .vertical
        texts.spacing = 2
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [icon, texts, control])
        row.spacing = 12
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 14)
        return row
    }

    private func card(_ content: UIView, palette: ChromePalette) -> UIView {
        let card = UIView()
        card.backgroundColor = palette.field
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        return card
    }

    private func statTile(_ value: UILabel, caption: String, id: String, palette: ChromePalette) -> UIView {
        value.font = .monospacedDigitSystemFont(ofSize: 26, weight: .bold)
        value.textColor = Theme.violet
        value.textAlignment = .center
        value.accessibilityIdentifier = id
        let captionLabel = UILabel()
        captionLabel.text = caption
        captionLabel.numberOfLines = 2
        captionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        captionLabel.textColor = Theme.dim
        captionLabel.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [value, captionLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 6, bottom: 12, trailing: 6)
        return card(stack, palette: palette)
    }

    private func configureButton(_ button: UIButton, title: String, symbol: String, palette: ChromePalette) {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.image = UIImage(systemName: symbol)
        config.imagePadding = 6
        config.preferredSymbolConfigurationForImage = .init(pointSize: 13, weight: .semibold)
        config.baseBackgroundColor = palette.field
        config.baseForegroundColor = Theme.violet
        config.cornerStyle = .large
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
            return a
        }
        button.configuration = config
    }
}

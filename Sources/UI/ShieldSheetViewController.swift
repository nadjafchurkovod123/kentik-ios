import UIKit

/// Компактная шторка щита, как в AdBlock: общий выключатель, выключатель для сайта,
/// счётчики заблокированного, обновление списков и переход в настройки.
final class ShieldSheetViewController: UIViewController {

    private let shield: ShieldControlling
    private weak var currentTab: Tab?
    private let incognito: Bool
    /// Открыть настройки (шторка к этому моменту уже закрыта).
    var onOpenSettings: (() -> Void)?

    private let content = UIStackView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let globalSwitch = UISwitch()
    private let siteSwitch = UISwitch()
    private let siteTitle = UILabel()
    private let siteSubtitle = UILabel()
    private var stats: [StatKind: StatTile] = [:]
    private let updateButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let versionLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var updating = false
    /// Итог последнего «Обновить списки» («Списки уже свежие» и т. п.).
    private var updateMessage: String?

    private var host: String? { currentTab?.host }

    /// Счётчик в шторке.
    enum StatKind: CaseIterable {
        case popups, redirects, hidden
    }

    private final class StatTile {
        let card: UIView
        let value: UILabel
        let caption: UILabel

        init(card: UIView, value: UILabel, caption: UILabel) {
            self.card = card
            self.value = value
            self.caption = caption
        }
    }

    init(shield: ShieldControlling, tab: Tab?) {
        self.shield = shield
        self.currentTab = tab
        self.incognito = tab?.isIncognito ?? false
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            // Высота по содержимому: с крупным текстом (Dynamic Type) шторка растёт.
            sheet.detents = [.custom(identifier: .init("shield")) { [weak self] context in
                MainActor.assumeIsolated {
                    let maximum = context.maximumDetentValue
                    return self?.preferredSheetHeight(maximum: maximum) ?? min(420, maximum)
                }
            }, .large()]
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

        // Заголовок: «Блокировка рекламы» — «Включена на …» (род согласован).
        iconView.preferredSymbolConfiguration = .init(pointSize: 26, weight: .semibold)
        iconView.contentMode = .center
        let iconHolder = UIView()
        iconHolder.layer.cornerRadius = 22
        iconHolder.backgroundColor = palette.field
        iconHolder.addSubview(iconView)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Блокировка рекламы"
        style(titleLabel, Theme.font(20, .bold, style: .title3, maximum: 28))
        titleLabel.accessibilityTraits = .header
        style(statusLabel, Theme.font(13, .medium, style: .subheadline, maximum: 20), color: Theme.dim)
        statusLabel.accessibilityIdentifier = "shieldStatus"
        statusLabel.numberOfLines = 0
        let titles = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        titles.axis = .vertical
        titles.spacing = 2
        let header = UIStackView(arrangedSubviews: [iconHolder, titles])
        header.spacing = 12
        header.alignment = .center

        // Переключатели: у каждого своё имя для VoiceOver.
        globalSwitch.onTintColor = Theme.violet
        globalSwitch.accessibilityIdentifier = "shieldGlobalSwitch"
        globalSwitch.accessibilityLabel = "Блокировка рекламы везде"
        globalSwitch.addTarget(self, action: #selector(globalChanged), for: .valueChanged)
        siteSwitch.onTintColor = Theme.violet
        siteSwitch.accessibilityIdentifier = "shieldSiteSwitch"
        siteSwitch.addTarget(self, action: #selector(siteChanged), for: .valueChanged)

        let globalTitle = UILabel()
        globalTitle.text = "Везде"
        style(globalTitle, Theme.font(16, .semibold, style: .body, maximum: 24))
        let globalSubtitle = UILabel()
        globalSubtitle.text = "Реклама, всплывающие окна, переходы"
        style(globalSubtitle, Theme.font(12, style: .caption1, maximum: 18), color: Theme.faint)
        globalSubtitle.numberOfLines = 0
        let globalRow = row(symbol: "shield.lefthalf.filled", title: globalTitle, subtitle: globalSubtitle, control: globalSwitch)
        siteTitle.text = "На этом сайте"
        style(siteTitle, Theme.font(16, .semibold, style: .body, maximum: 24))
        style(siteSubtitle, Theme.font(12, style: .caption1, maximum: 18), color: Theme.faint)
        siteSubtitle.lineBreakMode = .byTruncatingMiddle
        siteSubtitle.numberOfLines = 2
        let siteRow = row(symbol: "globe", title: siteTitle, subtitle: siteSubtitle, control: siteSwitch)

        let divider = UIView()
        divider.backgroundColor = palette.line
        divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        let switches = UIStackView(arrangedSubviews: [globalRow, divider, siteRow])
        switches.axis = .vertical
        switches.spacing = 0
        let switchesCard = card(switches, palette: palette)

        // Счётчики: каждая плитка — один элемент для VoiceOver («3 окна заблокировано»).
        let ids: [StatKind: String] = [.popups: "shieldPopupsCount", .redirects: "shieldRedirectsCount",
                                       .hidden: "shieldHiddenCount"]
        let tiles = StatKind.allCases.map { kind -> UIView in
            let tile = statTile(id: ids[kind] ?? "", palette: palette)
            stats[kind] = tile
            return tile.card
        }
        let statsRow = UIStackView(arrangedSubviews: tiles)
        statsRow.axis = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = 10

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

        style(versionLabel, Theme.font(12, style: .caption1, maximum: 18), color: Theme.faint)
        versionLabel.textAlignment = .center
        versionLabel.numberOfLines = 0
        versionLabel.accessibilityIdentifier = "shieldListsStatus"
        spinner.color = Theme.violet
        spinner.hidesWhenStopped = true

        [header, switchesCard, statsRow, buttons, versionLabel].forEach(content.addArrangedSubview)
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
            buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),

            spinner.trailingAnchor.constraint(equalTo: updateButton.trailingAnchor, constant: -10),
            spinner.centerYAnchor.constraint(equalTo: updateButton.centerYAnchor),
        ])

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(refresh), name: .shieldSettingsChanged, object: nil)
        // Ход подготовки и замена списков — здесь же, а не плашкой поверх шторки.
        center.addObserver(self, selector: #selector(refresh), name: .contentBlockerStatusChanged, object: nil)
        center.addObserver(self, selector: #selector(refresh), name: .contentBlockerListsChanged, object: nil)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: ShieldSheetViewController, _: UITraitCollection) in
            controller.sheetPresentationController?.invalidateDetents()
        }
        refresh()
    }

    // MARK: - Состояние

    @objc func refresh() {
        guard isViewLoaded else { return }
        let global = shield.isEnabledGlobally
        let site = shield.isEnabled(forHost: host, incognito: incognito)
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
        siteSwitch.accessibilityLabel = hostText.isEmpty ? "Блокировка на этом сайте" : "Блокировка на \(hostText)"
        // В инкогнито выключатель сайта временный — так и пишем.
        siteSubtitle.text = hostText.isEmpty ? "Откройте сайт" : (incognito ? "\(hostText) · до закрытия инкогнито" : hostText)
        siteTitle.alpha = siteSwitch.isEnabled ? 1 : 0.5

        var listsVersion = ContentBlocker.shared.activeVersion ?? FilterLists.version
        var counts: [StatKind: Int] = [.popups: 0, .redirects: 0, .hidden: 0]
        if let tab = currentTab {
            let tabStats = shield.stats(for: tab)
            counts = [.popups: tabStats.blockedPopups, .redirects: tabStats.blockedRedirects,
                      .hidden: tabStats.hiddenElements]
            listsVersion = tabStats.listsVersion
        }
        for (kind, tile) in stats {
            let n = counts[kind] ?? 0
            let caption = Self.statCaption(n, kind)
            tile.value.text = "\(n)"
            tile.caption.text = caption.replacingOccurrences(of: " ", with: "\n")
            tile.card.accessibilityLabel = "\(n) \(caption)"
        }

        // Списки: подготовка, итог обновления, неполная блокировка, дата и последняя проверка.
        var lines: [String] = []
        var warn = false
        if let status = ContentBlocker.shared.statusText {
            lines.append(status)
        }
        if let updateMessage { lines.append(updateMessage) }
        if let incomplete = Self.incompleteText() {
            lines.append(incomplete)
            warn = true
        }
        let freshness = FilterLists.freshness(version: listsVersion, lastCheck: FilterListUpdater.shared.lastCheck)
        lines.append(freshness.text)
        warn = warn || freshness.isStale
        let text = lines.joined(separator: "\n")
        if versionLabel.text != text {
            versionLabel.text = text
            sheetPresentationController?.invalidateDetents()
        }
        versionLabel.textColor = warn ? Theme.warn : Theme.faint
        if updating || ContentBlocker.shared.statusText != nil {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }

    /// Подпись счётчика с согласованием: «1 окно заблокировано», «2 окна заблокированы»,
    /// «5 окон заблокировано».
    static func statCaption(_ n: Int, _ kind: StatKind) -> String {
        switch kind {
        case .popups:
            return RussianPlural.form(n, "окно", "окна", "окон") + " "
                + RussianPlural.form(n, "заблокировано", "заблокированы", "заблокировано")
        case .redirects:
            return RussianPlural.form(n, "переход", "перехода", "переходов") + " "
                + RussianPlural.form(n, "заблокирован", "заблокированы", "заблокировано")
        case .hidden:
            return RussianPlural.form(n, "элемент", "элемента", "элементов") + " "
                + RussianPlural.form(n, "скрыт", "скрыты", "скрыто")
        }
    }

    /// Предупреждение, если часть списков (или все) не скомпилировалась.
    static func incompleteText() -> String? {
        let failed = ContentBlocker.shared.failedLists.count
        guard failed > 0 else { return nil }
        if ContentBlocker.shared.activeVersion == nil {
            return "Блокировка рекламы не работает: списки фильтров не загрузились. Освободите место и перезапустите Kentik"
        }
        return "Блокировка неполная: не "
            + RussianPlural.form(failed, "загрузился", "загрузились", "загрузились")
            + " \(failed) " + RussianPlural.form(failed, "список", "списка", "списков")
    }

    @objc private func globalChanged() {
        UISelectionFeedbackGenerator().selectionChanged()
        shield.isEnabledGlobally = globalSwitch.isOn
        refresh()
    }

    @objc private func siteChanged() {
        guard let host else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        shield.setEnabled(siteSwitch.isOn, forHost: host, incognito: incognito)
        refresh()
    }

    @objc private func updateLists() {
        updateButton.isEnabled = false
        updating = true
        updateMessage = nil
        refresh()
        let before = ContentBlocker.shared.activeVersion
        // Страница не перезагружается: новые правила действуют со следующей загрузки.
        shield.reloadRules { [weak self] error in
            guard let self else { return }
            self.updating = false
            self.updateButton.isEnabled = true
            let message: String
            if let error {
                message = "Не удалось обновить списки: \(error.localizedDescription)"
            } else if ContentBlocker.shared.activeVersion != before {
                message = "Списки обновлены — действуют со следующей загрузки страницы"
            } else {
                message = "Списки уже свежие"
            }
            self.updateMessage = message
            self.refresh()
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    @objc private func openSettings() {
        let callback = onOpenSettings
        dismiss(animated: true) { callback?() }
    }

    /// Высота шторки по содержимому (не больше доступной).
    private func preferredSheetHeight(maximum: CGFloat) -> CGFloat {
        loadViewIfNeeded()
        let screenWidth = view.window?.bounds.width ?? view.bounds.width
        let width = max(200, (screenWidth > 0 ? screenWidth : 390) - 36)
        let size = content.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return min(maximum, ceil(size.height) + 26 + 24)
    }

    // MARK: - Сборка

    private func style(_ label: UILabel, _ font: UIFont, color: UIColor = Theme.text) {
        label.font = font
        label.textColor = color
        label.adjustsFontForContentSizeCategory = true
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

    private func statTile(id: String, palette: ChromePalette) -> StatTile {
        let value = UILabel()
        value.font = Theme.digits(26, .bold, style: .title2, maximum: 34)
        value.adjustsFontForContentSizeCategory = true
        value.textColor = Theme.violet
        value.textAlignment = .center
        let caption = UILabel()
        caption.numberOfLines = 0
        style(caption, Theme.font(11, .medium, style: .caption2, maximum: 16), color: Theme.dim)
        caption.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [value, caption])
        stack.axis = .vertical
        stack.spacing = 2
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 6, bottom: 12, trailing: 6)
        let tile = card(stack, palette: palette)
        tile.isAccessibilityElement = true
        tile.accessibilityIdentifier = id
        return StatTile(card: tile, value: value, caption: caption)
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
            a.font = Theme.font(14, .semibold, style: .subheadline, maximum: 19)
            return a
        }
        button.configuration = config
    }
}

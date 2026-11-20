import UIKit

/// Домашний экран пустой вкладки: обои с акулой в короне, как на десктопе, поле поиска и
/// плитки (закреплённые + частые из истории). В инкогнито — карточка «что не сохраняется»,
/// плиток нет (инкогнито ничему не учит домашний экран).
final class HomeView: UIView, UIContextMenuInteractionDelegate {

    /// Нажали на поле поиска.
    var onSearchTap: (() -> Void)?
    /// Открыть адрес (background — в фоновой вкладке).
    var onOpen: ((URL, Bool) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let imageView = UIImageView(image: UIImage(named: "Wallpaper"))
    private let searchControl = UIControl()
    private let searchIcon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private let searchLabel = UILabel()
    private let tilesTitle = UILabel()
    private let tilesGrid = UIStackView()
    private let incognitoCard = UIView()
    private var tiles: [HomeTile] = []
    private var incognito = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        accessibilityIdentifier = "homeView"

        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        // Обои 16:9 на чёрном — вписываем целиком, чтобы акула с короной не обрезалась.
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isAccessibilityElement = false

        buildSearch()
        buildIncognitoCard()

        tilesTitle.text = "Сайты"
        tilesTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        tilesTitle.textColor = Theme.dim
        tilesGrid.axis = .vertical
        tilesGrid.spacing = 14

        let imageHolder = UIView()
        imageHolder.addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(imageHolder)
        stack.addArrangedSubview(wrap(searchControl, inset: 16))
        stack.addArrangedSubview(wrap(incognitoCard, inset: 16))
        stack.addArrangedSubview(wrap(tilesTitle, inset: 22))
        stack.addArrangedSubview(wrap(tilesGrid, inset: 12))
        stack.setCustomSpacing(26, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(10, after: stack.arrangedSubviews[3])

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),

            // Картинка 16:9, по ширине экрана (не шире 600 pt), по центру.
            imageView.topAnchor.constraint(equalTo: imageHolder.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: imageHolder.bottomAnchor),
            imageView.centerXAnchor.constraint(equalTo: imageHolder.centerXAnchor),
            imageView.widthAnchor.constraint(lessThanOrEqualTo: imageHolder.widthAnchor),
            imageView.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 1440.0 / 2560.0),
        ])
        let fullWidth = imageView.widthAnchor.constraint(equalTo: imageHolder.widthAnchor)
        fullWidth.priority = .defaultHigh
        fullWidth.isActive = true

        reload(incognito: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    private func wrap(_ view: UIView, inset: CGFloat) -> UIView {
        let holder = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: holder.topAnchor),
            view.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -inset),
        ])
        return holder
    }

    private func buildSearch() {
        searchControl.layer.cornerRadius = 16
        searchControl.layer.cornerCurve = .continuous
        searchControl.layer.borderWidth = 1
        searchControl.accessibilityIdentifier = "homeSearch"
        searchControl.accessibilityLabel = "Поиск или адрес"
        searchControl.isAccessibilityElement = true
        searchControl.accessibilityTraits = .button
        searchControl.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)
        searchControl.addTarget(self, action: #selector(searchDown), for: [.touchDown, .touchDragEnter])
        searchControl.addTarget(self, action: #selector(searchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])

        searchIcon.tintColor = Theme.dim
        searchIcon.preferredSymbolConfiguration = .init(pointSize: 16, weight: .semibold)
        searchLabel.font = .systemFont(ofSize: 17)
        searchLabel.textColor = Theme.faint
        [searchIcon, searchLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.isUserInteractionEnabled = false
            searchControl.addSubview($0)
        }
        NSLayoutConstraint.activate([
            searchControl.heightAnchor.constraint(equalToConstant: 52),
            searchIcon.leadingAnchor.constraint(equalTo: searchControl.leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: searchControl.centerYAnchor),
            searchLabel.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            searchLabel.trailingAnchor.constraint(lessThanOrEqualTo: searchControl.trailingAnchor, constant: -16),
            searchLabel.centerYAnchor.constraint(equalTo: searchControl.centerYAnchor),
        ])
    }

    private func buildIncognitoCard() {
        incognitoCard.backgroundColor = Theme.barIncognito.withAlphaComponent(0.92)
        incognitoCard.layer.cornerRadius = 18
        incognitoCard.layer.cornerCurve = .continuous
        incognitoCard.layer.borderWidth = 1
        incognitoCard.layer.borderColor = Theme.surfaceIncognito.cgColor
        incognitoCard.accessibilityIdentifier = "incognitoHome"

        let icon = UIImageView(image: UIImage(systemName: "eye.slash.fill"))
        icon.tintColor = Theme.violet
        icon.preferredSymbolConfiguration = .init(pointSize: 22, weight: .semibold)
        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let title = UILabel()
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.text = "Режим инкогнито"
        title.font = .systemFont(ofSize: 19, weight: .bold)
        title.textColor = Theme.text
        let header = UIStackView(arrangedSubviews: [icon, title])
        header.spacing = 10
        header.alignment = .center

        let lines = [
            ("clock.arrow.circlepath", "История и плитки не запоминаются"),
            ("trash", "Куки, кэш и входы на сайты стираются, когда закрыта последняя вкладка инкогнито"),
            ("rectangle.on.rectangle.slash", "Содержимое прячется в переключателе приложений"),
        ]
        let body = UIStackView()
        body.axis = .vertical
        body.spacing = 10
        for (symbol, text) in lines {
            let i = UIImageView(image: UIImage(systemName: symbol))
            i.tintColor = Theme.violet
            i.preferredSymbolConfiguration = .init(pointSize: 13, weight: .semibold)
            i.setContentHuggingPriority(.required, for: .horizontal)
            i.widthAnchor.constraint(equalToConstant: 22).isActive = true
            i.contentMode = .center
            let l = UILabel()
            l.text = text
            l.numberOfLines = 0
            l.font = .systemFont(ofSize: 14)
            l.textColor = Theme.dim
            let row = UIStackView(arrangedSubviews: [i, l])
            row.spacing = 8
            row.alignment = .firstBaseline
            body.addArrangedSubview(row)
        }
        let content = UIStackView(arrangedSubviews: [header, body])
        content.axis = .vertical
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        incognitoCard.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: incognitoCard.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: incognitoCard.bottomAnchor, constant: -18),
            content.leadingAnchor.constraint(equalTo: incognitoCard.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: incognitoCard.trailingAnchor, constant: -18),
        ])
    }

    @objc private func searchTapped() { onSearchTap?() }

    @objc private func searchDown() {
        UIView.animate(withDuration: Theme.fast) { self.searchControl.transform = CGAffineTransform(scaleX: 0.98, y: 0.98) }
    }

    @objc private func searchUp() {
        UIView.animate(withDuration: Theme.mid, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
            self.searchControl.transform = .identity
        }
    }

    // MARK: - Содержимое

    func reload(incognito: Bool) {
        self.incognito = incognito
        let palette = ChromePalette.forIncognito(incognito)
        backgroundColor = incognito ? Theme.incognitoBackground : .black
        imageView.alpha = incognito ? 0.45 : 1
        searchControl.backgroundColor = palette.bar.withAlphaComponent(0.94)
        searchControl.layer.borderColor = (incognito ? Theme.surfaceIncognito : palette.line).cgColor
        searchLabel.text = incognito ? "Инкогнито: поиск или адрес" : "Поиск или адрес"
        searchIcon.image = UIImage(systemName: incognito ? "eye.slash" : "magnifyingglass")
        searchIcon.tintColor = incognito ? Theme.violet : Theme.dim

        incognitoCard.superview?.isHidden = !incognito
        tiles = incognito ? [] : TileStore.shared.tiles()
        tilesTitle.superview?.isHidden = tiles.isEmpty
        tilesGrid.superview?.isHidden = tiles.isEmpty
        rebuildTiles()
    }

    private func rebuildTiles() {
        tilesGrid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let columns = 4
        var index = 0
        while index < tiles.count {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 6
            for column in 0..<columns {
                let i = index + column
                if i < tiles.count {
                    let view = TileView(tile: tiles[i])
                    view.addTarget(self, action: #selector(tileTapped(_:)), for: .touchUpInside)
                    view.addInteraction(UIContextMenuInteraction(delegate: self))
                    row.addArrangedSubview(view)
                } else {
                    row.addArrangedSubview(UIView())
                }
            }
            tilesGrid.addArrangedSubview(row)
            index += columns
        }
    }

    @objc private func tileTapped(_ sender: TileView) {
        onOpen?(sender.tile.url, false)
    }

    // MARK: - Долгое нажатие на плитку

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let tileView = interaction.view as? TileView else { return nil }
        let tile = tileView.tile
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let openBackground = UIAction(title: "Открыть в фоновой вкладке", image: UIImage(systemName: "square.on.square")) { _ in
                self?.onOpen?(tile.url, true)
            }
            let pin = tile.pinned
                ? UIAction(title: "Открепить", image: UIImage(systemName: "pin.slash")) { _ in
                    TileStore.shared.unpin(tile)
                    self?.reload(incognito: false)
                }
                : UIAction(title: "Закрепить", image: UIImage(systemName: "pin")) { _ in
                    TileStore.shared.pin(tile)
                    self?.reload(incognito: false)
                }
            let remove = UIAction(title: "Убрать", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                TileStore.shared.remove(tile)
                self?.reload(incognito: false)
            }
            return UIMenu(title: tile.host, children: [openBackground, pin, remove])
        }
    }
}

/// Плитка сайта: квадрат с буквой и подпись.
final class TileView: UIControl {

    let tile: HomeTile
    private let box = UIView()

    private static let colors: [UInt32] = [0x6D4AFF, 0x8B5CF6, 0xA855F7, 0x7C3AED, 0x9333EA, 0x5B3DC8, 0xC026D3, 0x4F46E5]

    init(tile: HomeTile) {
        self.tile = tile
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = tile.host
        accessibilityIdentifier = "homeTile"

        let hash = tile.host.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        box.backgroundColor = UIColor(hex: Self.colors[hash % Self.colors.count])
        box.layer.cornerRadius = 16
        box.layer.cornerCurve = .continuous
        box.isUserInteractionEnabled = false

        let letter = UILabel()
        let first = tile.host.first.map { String($0).uppercased() } ?? "•"
        letter.text = first
        letter.font = .systemFont(ofSize: 24, weight: .bold)
        letter.textColor = .white
        letter.textAlignment = .center

        let label = UILabel()
        label.text = tile.title.isEmpty ? tile.host : tile.title
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Theme.text
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.8
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero

        let pin = UIImageView(image: UIImage(systemName: "pin.fill"))
        pin.tintColor = .white
        pin.preferredSymbolConfiguration = .init(pointSize: 9, weight: .bold)
        pin.isHidden = !tile.pinned

        [box, letter, label, pin].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.isUserInteractionEnabled = false
        }
        addSubview(box)
        box.addSubview(letter)
        box.addSubview(pin)
        addSubview(label)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor),
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.widthAnchor.constraint(equalToConstant: 60),
            box.heightAnchor.constraint(equalToConstant: 60),
            letter.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            letter.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            pin.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            pin.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: Theme.fast) {
                self.box.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
                self.box.alpha = self.isHighlighted ? 0.85 : 1
            }
        }
    }
}

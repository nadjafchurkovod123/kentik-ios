import UIKit

/// Переключатель вкладок: сетка карточек как в Safari, два раздела — «Вкладки» и «Инкогнито».
/// Закрыть — крестиком или смахиванием карточки вбок.
final class TabSwitcherViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    private let tabManager: TabManager
    private(set) var showingIncognito: Bool
    /// Переключатель закрыт; true — открыта новая вкладка (надо поставить фокус в адрес).
    var onFinish: ((Bool) -> Void)?

    private let segment = UISegmentedControl(items: ["Вкладки", "Инкогнито"])
    private let layout = UICollectionViewFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let emptyStack = UIStackView()
    private let emptyIcon = UIImageView()
    private let emptyLabel = UILabel()
    private let bottomBar = UIView()
    private let closeAllButton = UIButton(type: .system)
    private let addButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private var lockView: IncognitoLockView?

    private var tabs: [Tab] { showingIncognito ? tabManager.incognitoTabs : tabManager.normalTabs }

    /// Раздел «Инкогнито» заперт Face ID.
    private var isIncognitoLocked: Bool {
        showingIncognito && IncognitoLock.shared.isLocked && !tabManager.incognitoTabs.isEmpty
    }

    /// Карточки в коллекции. Пока инкогнито заперто, их нет вовсе: ни заголовков, ни снимков
    /// не попадает ни на экран (даже на миг во время перехода между разделами), ни в дерево
    /// доступности — замок не прикрывает карточки, а заменяет их.
    private var visibleTabs: [Tab] { isIncognitoLocked ? [] : tabs }

    init(tabManager: TabManager, incognito: Bool) {
        self.tabManager = tabManager
        self.showingIncognito = incognito
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "tabSwitcher"

        segment.selectedSegmentIndex = showingIncognito ? 1 : 0
        segment.accessibilityIdentifier = "tabSwitcherSegment"
        segment.setTitleTextAttributes([.foregroundColor: Theme.dim, .font: UIFont.systemFont(ofSize: 14, weight: .semibold)], for: .normal)
        segment.setTitleTextAttributes([.foregroundColor: Theme.background, .font: UIFont.systemFont(ofSize: 14, weight: .bold)], for: .selected)
        segment.selectedSegmentTintColor = Theme.violet
        segment.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)

        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 18
        layout.sectionInset = UIEdgeInsets(top: 12, left: 16, bottom: 20, right: 16)
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.register(TabCell.self, forCellWithReuseIdentifier: TabCell.reuseID)

        emptyIcon.tintColor = Theme.violet
        emptyIcon.preferredSymbolConfiguration = .init(pointSize: 40, weight: .semibold)
        emptyLabel.font = Theme.font(15, style: .body, maximum: 20)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = Theme.dim
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyStack.axis = .vertical
        emptyStack.alignment = .center
        emptyStack.spacing = 14
        emptyStack.addArrangedSubview(emptyIcon)
        emptyStack.addArrangedSubview(emptyLabel)
        emptyStack.isUserInteractionEnabled = false

        closeAllButton.setTitle("Закрыть все", for: .normal)
        closeAllButton.titleLabel?.font = Theme.font(16, .medium, style: .body, maximum: 20)
        closeAllButton.titleLabel?.adjustsFontForContentSizeCategory = true
        closeAllButton.tintColor = Theme.bad
        closeAllButton.showsMenuAsPrimaryAction = true
        closeAllButton.accessibilityIdentifier = "closeAllTabs"

        addButton.setImage(UIImage(systemName: "plus"), for: .normal)
        addButton.setPreferredSymbolConfiguration(.init(pointSize: 20, weight: .bold), forImageIn: .normal)
        addButton.tintColor = Theme.background
        addButton.backgroundColor = Theme.violet
        addButton.layer.cornerRadius = 22
        addButton.accessibilityLabel = "Новая вкладка"
        addButton.accessibilityIdentifier = "newTabInSwitcher"
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)

        doneButton.setTitle("Готово", for: .normal)
        doneButton.titleLabel?.font = Theme.font(16, .bold, style: .body, maximum: 20)
        doneButton.titleLabel?.adjustsFontForContentSizeCategory = true
        doneButton.tintColor = Theme.violet
        doneButton.accessibilityIdentifier = "doneTabs"
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

        [segment, collectionView, emptyStack, bottomBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        [closeAllButton, addButton, doneButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview($0)
        }

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            segment.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            segment.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            segment.widthAnchor.constraint(equalToConstant: 280),
            segment.heightAnchor.constraint(equalToConstant: 36),

            collectionView.topAnchor.constraint(equalTo: segment.bottomAnchor, constant: 8),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            emptyStack.centerXAnchor.constraint(equalTo: collectionView.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 60),

            closeAllButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 20),
            closeAllButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            addButton.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            addButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 44),
            addButton.heightAnchor.constraint(equalToConstant: 44),
            doneButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -22),
            doneButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(lockChanged),
                                               name: .incognitoLockChanged, object: nil)
        applyMode(animated: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        collectionView.layoutIfNeeded()
        if let selected = tabManager.selectedTab, let index = visibleTabs.firstIndex(where: { $0 === selected }),
           index < collectionView.numberOfItems(inSection: 0) {
            collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: false)
        }
        // Карточки чуть «вырастают» при открытии — дёшево, только transform.
        collectionView.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        UIView.animate(withDuration: Theme.slow, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) {
            self.collectionView.transform = .identity
        }
    }

    // MARK: - Режим

    private func applyMode(animated: Bool) {
        let palette = ChromePalette.forIncognito(showingIncognito)
        let changes = {
            self.view.backgroundColor = palette.background
            self.bottomBar.backgroundColor = palette.background
            self.segment.backgroundColor = palette.bar
        }
        // Замок — раньше перезагрузки: запертый раздел и так без карточек, но экран замка
        // должен стоять сразу, а не проявляться после перехода.
        updateLock()
        if animated {
            UIView.animate(withDuration: Theme.mid, animations: changes)
            UIView.transition(with: collectionView, duration: Theme.mid, options: .transitionCrossDissolve) {
                self.collectionView.reloadData()
            }
        } else {
            changes()
            collectionView.reloadData()
        }
        updateCounts()
    }

    private func updateCounts() {
        segment.setTitle("Вкладки · \(tabManager.normalTabs.count)", forSegmentAt: 0)
        segment.setTitle("Инкогнито · \(tabManager.incognitoTabs.count)", forSegmentAt: 1)
        let empty = tabs.isEmpty
        emptyStack.isHidden = !empty || isIncognitoLocked
        if showingIncognito {
            emptyIcon.image = UIImage(systemName: "eye.slash.fill")
            emptyLabel.text = "Вкладок инкогнито нет.\nИстория, куки и кэш инкогнито не сохраняются и стираются после последней вкладки."
        } else {
            emptyIcon.image = UIImage(systemName: "square.on.square")
            emptyLabel.text = "Вкладок нет"
        }
        closeAllButton.isEnabled = !empty
        closeAllButton.alpha = empty ? 0.4 : 1
        let count = tabs.count
        let title = showingIncognito ? "Закрыть все вкладки инкогнито (\(count))" : "Закрыть все вкладки (\(count))"
        let confirm = UIAction(title: title, image: UIImage(systemName: "xmark.square"), attributes: .destructive) { [weak self] _ in
            self?.closeAll()
        }
        closeAllButton.menu = UIMenu(title: "", children: [confirm])
    }

    private func updateLock() {
        let locked = isIncognitoLocked
        collectionView.accessibilityElementsHidden = locked
        if locked, lockView == nil {
            let lock = IncognitoLockView()
            lock.onUnlock = { [weak self] in self?.unlock() }
            lock.translatesAutoresizingMaskIntoConstraints = false
            view.insertSubview(lock, belowSubview: bottomBar)
            NSLayoutConstraint.activate([
                lock.topAnchor.constraint(equalTo: collectionView.topAnchor),
                lock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                lock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                lock.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor),
            ])
            lockView = lock
        } else if !locked {
            lockView?.removeFromSuperview()
            lockView = nil
        }
    }

    private func unlock() {
        IncognitoLock.shared.unlock { _ in }
    }

    /// Замок закрылся (приложение ушло в фон, пока переключатель открыт) или открылся.
    @objc private func lockChanged() {
        guard isViewLoaded else { return }
        updateLock()
        if showingIncognito {
            if IncognitoLock.shared.isLocked {
                collectionView.reloadData()
            } else {
                UIView.transition(with: collectionView, duration: Theme.mid, options: .transitionCrossDissolve) {
                    self.collectionView.reloadData()
                }
            }
        }
        updateCounts()
    }

    @objc private func segmentChanged() {
        showingIncognito = segment.selectedSegmentIndex == 1
        applyMode(animated: true)
    }

    /// Обновить снимки (после того как BrowserViewController снял текущую вкладку).
    func reloadSnapshots() {
        guard isViewLoaded else { return }
        collectionView.reloadData()
    }

    // MARK: - Действия

    @objc private func addTapped() {
        if isIncognitoLocked {
            // Новая вкладка инкогнито открывает браузер в запертом инкогнито — сначала Face ID.
            IncognitoLock.shared.unlock { [weak self] ok in
                guard ok, let self else { return }
                self.tabManager.addTab(incognito: true)
                self.finish(newTab: true)
            }
            return
        }
        tabManager.addTab(incognito: showingIncognito)
        finish(newTab: true)
    }

    @objc private func doneTapped() {
        let list = tabs
        if list.isEmpty {
            tabManager.addTab(incognito: showingIncognito)
            finish(newTab: true)
            return
        }
        if let selected = tabManager.selectedTab, list.contains(where: { $0 === selected }) {
            finish(newTab: false)
        } else if let last = list.last {
            tabManager.select(last)
            finish(newTab: false)
        }
    }

    private func finish(newTab: Bool) {
        let callback = onFinish
        dismiss(animated: true) { callback?(newTab) }
    }

    private func close(_ tab: Tab) {
        guard let index = visibleTabs.firstIndex(where: { $0 === tab }) else { return }
        tabManager.close(tab)
        SnapshotCache.shared.set(nil, for: tab)
        collectionView.performBatchUpdates({
            self.collectionView.deleteItems(at: [IndexPath(item: index, section: 0)])
        }, completion: { _ in
            self.collectionView.reloadData()
        })
        updateCounts()
        updateLock()
    }

    private func closeAll() {
        let list = tabs
        if showingIncognito {
            tabManager.closeAllIncognitoTabs()
        } else {
            list.forEach { tabManager.close($0) }
        }
        list.forEach { SnapshotCache.shared.set(nil, for: $0) }
        UIView.transition(with: collectionView, duration: Theme.mid, options: .transitionCrossDissolve) {
            self.collectionView.reloadData()
        }
        updateCounts()
        updateLock()
    }

    // MARK: - Коллекция

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        visibleTabs.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TabCell.reuseID, for: indexPath) as! TabCell
        let tab = visibleTabs[indexPath.item]
        cell.configure(with: tab, selected: tab === tabManager.selectedTab, snapshot: SnapshotCache.shared.image(for: tab))
        cell.onClose = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.close(tab)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let columns: CGFloat = collectionView.bounds.width > 600 ? 3 : 2
        let width = collectionView.bounds.width - 16 * 2 - (columns - 1) * 14
        let item = floor(width / columns)
        return CGSize(width: item, height: floor(item * 1.4))
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let visible = visibleTabs
        guard indexPath.item < visible.count else { return }
        let tab = visible[indexPath.item]
        if let cell = collectionView.cellForItem(at: indexPath) {
            UIView.animate(withDuration: Theme.fast) { cell.transform = CGAffineTransform(scaleX: 1.04, y: 1.04) }
        }
        tabManager.select(tab)
        finish(newTab: false)
    }
}

/// Карточка вкладки.
final class TabCell: UICollectionViewCell, UIGestureRecognizerDelegate {

    static let reuseID = "TabCell"

    var onClose: (() -> Void)?

    private let card = UIView()
    private let header = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let imageView = UIImageView()
    private let placeholder = UILabel()
    private lazy var swipe = UIPanGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.layer.borderWidth = 1
        card.accessibilityIdentifier = "tabCell"

        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = .init(pointSize: 11, weight: .semibold)
        titleLabel.font = Theme.font(13, .semibold, style: .footnote, maximum: 16)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingTail

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.setPreferredSymbolConfiguration(.init(pointSize: 12, weight: .bold), forImageIn: .normal)
        closeButton.tintColor = Theme.dim
        closeButton.accessibilityIdentifier = "closeTab"
        closeButton.accessibilityLabel = "Закрыть вкладку"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        placeholder.font = .systemFont(ofSize: 44, weight: .bold)
        placeholder.textAlignment = .center

        contentView.addSubview(card)
        [header, imageView, placeholder].forEach { card.addSubview($0) }
        [iconView, titleLabel, closeButton].forEach { header.addSubview($0) }
        [card, header, imageView, placeholder, iconView, titleLabel, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            header.topAnchor.constraint(equalTo: card.topAnchor),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 36),

            iconView.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            closeButton.topAnchor.constraint(equalTo: header.topAnchor),
            closeButton.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 38),

            imageView.topAnchor.constraint(equalTo: header.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
        ])

        swipe.delegate = self
        contentView.addGestureRecognizer(swipe)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        card.transform = .identity
        card.alpha = 1
        transform = .identity
        imageView.image = nil
        // Карточка в очереди на повторное использование не хранит чужой заголовок.
        titleLabel.text = nil
        card.accessibilityLabel = nil
    }

    func configure(with tab: Tab, selected: Bool, snapshot: UIImage?) {
        let palette = ChromePalette.forIncognito(tab.isIncognito)
        card.backgroundColor = palette.bar
        header.backgroundColor = palette.bar
        imageView.backgroundColor = tab.isIncognito ? Theme.incognitoBackground : .black
        card.layer.borderWidth = selected ? 2.5 : 1
        card.layer.borderColor = (selected ? Theme.violet : palette.line).cgColor
        iconView.image = UIImage(systemName: tab.isIncognito ? "eye.slash.fill" : (tab.displayURL == nil ? "house.fill" : "globe"))
        iconView.tintColor = tab.isIncognito ? Theme.violet : Theme.dim
        titleLabel.text = tab.displayTitle
        card.accessibilityLabel = tab.displayTitle
        imageView.image = snapshot
        let host = displayHost(tab.displayURL?.host)
        placeholder.isHidden = snapshot != nil
        placeholder.text = host.first.map { String($0).uppercased() } ?? "K"
        placeholder.textColor = (tab.isIncognito ? Theme.violet : Theme.surface).withAlphaComponent(0.9)
        if snapshot == nil && tab.displayURL == nil {
            imageView.image = UIImage(named: "Wallpaper")
            imageView.alpha = tab.isIncognito ? 0.35 : 1
            placeholder.isHidden = true
        } else {
            imageView.alpha = 1
        }
    }

    @objc private func closeTapped() {
        UIView.animate(withDuration: Theme.mid, animations: {
            self.card.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            self.card.alpha = 0
        }, completion: { _ in self.onClose?() })
    }

    // MARK: - Смахивание

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipe else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let v = swipe.velocity(in: self)
        return abs(v.x) > abs(v.y) * 1.3
    }

    @objc private func handleSwipe(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self).x
        let width = max(bounds.width, 1)
        switch g.state {
        case .changed:
            card.transform = CGAffineTransform(translationX: t, y: 0).rotated(by: t / width * 0.08)
            card.alpha = 1 - min(abs(t) / width, 1) * 0.7
        case .ended, .cancelled:
            let v = g.velocity(in: self).x
            if g.state == .ended && (abs(t) > width * 0.45 || abs(v) > 900) {
                let direction: CGFloat = (t + v * 0.1) >= 0 ? 1 : -1
                UIView.animate(withDuration: Theme.mid, delay: 0, options: .curveEaseOut, animations: {
                    self.card.transform = CGAffineTransform(translationX: direction * width * 1.6, y: 0)
                    self.card.alpha = 0
                }, completion: { _ in self.onClose?() })
            } else {
                UIView.animate(withDuration: Theme.slow, delay: 0, usingSpringWithDamping: 0.75,
                               initialSpringVelocity: 0) {
                    self.card.transform = .identity
                    self.card.alpha = 1
                }
            }
        default:
            break
        }
    }
}

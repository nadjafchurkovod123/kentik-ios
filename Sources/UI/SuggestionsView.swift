import UIKit

/// Подсказки при вводе адреса: «искать…» / «перейти…» и совпадения из истории.
final class SuggestionsView: UIView, UITableViewDataSource, UITableViewDelegate {

    enum Item {
        case search(String)
        case open(URL)
        case history(HistoryEntry)
    }

    /// Выбран адрес.
    var onPick: ((URL) -> Void)?

    /// Адресная строка внизу: подсказки прижаты к низу, лучшая — последней, прямо над полем
    /// ввода (под большим пальцем), а не под «чёлкой».
    var bottomAligned = false {
        didSet {
            guard bottomAligned != oldValue else { return }
            tableView.reloadData()
            setNeedsLayout()
        }
    }

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var items: [Item] = []
    private var palette = ChromePalette.normal

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "suggestions"
        tableView.backgroundColor = .clear
        tableView.separatorColor = Theme.line
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 54, bottom: 0, right: 0)
        tableView.keyboardDismissMode = .onDrag
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 62
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    func applyPalette(_ palette: ChromePalette) {
        self.palette = palette
        backgroundColor = palette.background
        tableView.separatorColor = palette.line
        tableView.reloadData()
    }

    /// Пересчитать подсказки для введённого текста.
    func update(query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [Item] = []
        if !text.isEmpty {
            if let url = AddressParser.url(from: text), !url.absoluteString.hasPrefix(AddressParser.searchBase) {
                result.append(.open(url))
            }
            result.append(.search(text))
        }
        let history = text.isEmpty
            ? Array(HistoryStore.shared.entries.prefix(8))
            : HistoryStore.shared.suggestions(for: text, limit: 8)
        result += history.map { .history($0) }
        items = result
        tableView.reloadData()
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        alignRows()
    }

    /// Снизу: отступ сверху на свободное место и прокрутка к последней (лучшей) строке.
    private func alignRows() {
        guard bottomAligned else {
            if tableView.contentInset.top != 0 { tableView.contentInset.top = 0 }
            return
        }
        tableView.layoutIfNeeded()
        let contentHeight = tableView.contentSize.height
        let inset = max(0, tableView.bounds.height - contentHeight)
        if abs(tableView.contentInset.top - inset) > 0.5 { tableView.contentInset.top = inset }
        let offset = max(-inset, contentHeight - tableView.bounds.height)
        tableView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
    }

    /// Строка таблицы → подсказка (снизу порядок обратный: лучшая ближе к полю ввода).
    private func item(at row: Int) -> Item {
        bottomAligned ? items[items.count - 1 - row] : items[row]
    }

    // MARK: - Таблица

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.color = Theme.text
        content.textProperties.font = Theme.font(16, .medium, style: .body, maximum: 22)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.numberOfLines = 1
        content.secondaryTextProperties.color = Theme.faint
        content.secondaryTextProperties.font = Theme.font(13, style: .footnote, maximum: 18)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.numberOfLines = 1
        content.imageProperties.tintColor = Theme.violet
        content.imageProperties.preferredSymbolConfiguration = .init(pointSize: 16, weight: .semibold)
        content.imageProperties.reservedLayoutSize = CGSize(width: 26, height: 26)
        content.imageToTextPadding = 14

        switch item(at: indexPath.row) {
        case .search(let text):
            content.image = UIImage(systemName: "magnifyingglass")
            content.text = text
            content.secondaryText = "Искать в \(AppSettings.shared.searchEngine.title)"
        case .open(let url):
            content.image = UIImage(systemName: "arrow.up.right.circle")
            content.text = AddressBarView.displayText(for: url)
            content.secondaryText = "Перейти: \(url.absoluteString)"
        case .history(let entry):
            content.image = UIImage(systemName: "clock")
            content.imageProperties.tintColor = Theme.dim
            content.text = entry.title.isEmpty ? entry.host : entry.title
            content.secondaryText = entry.url.absoluteString
        }
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        let selected = UIView()
        selected.backgroundColor = palette.surface.withAlphaComponent(0.6)
        cell.selectedBackgroundView = selected
        cell.accessibilityIdentifier = "suggestion"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let url: URL?
        switch item(at: indexPath.row) {
        case .search(let text): url = AddressParser.searchURL(for: text)
        case .open(let u): url = u
        case .history(let entry): url = entry.url
        }
        if let url { onPick?(url) }
    }
}

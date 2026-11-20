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
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 56
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
        backgroundColor = palette.background.withAlphaComponent(0.98)
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
    }

    // MARK: - Таблица

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.color = Theme.text
        content.textProperties.font = .systemFont(ofSize: 16, weight: .medium)
        content.textProperties.numberOfLines = 1
        content.secondaryTextProperties.color = Theme.faint
        content.secondaryTextProperties.font = .systemFont(ofSize: 13)
        content.secondaryTextProperties.numberOfLines = 1
        content.imageProperties.tintColor = Theme.violet
        content.imageProperties.preferredSymbolConfiguration = .init(pointSize: 16, weight: .semibold)
        content.imageProperties.reservedLayoutSize = CGSize(width: 26, height: 26)
        content.imageToTextPadding = 14

        switch items[indexPath.row] {
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
        switch items[indexPath.row] {
        case .search(let text): url = AddressParser.searchURL(for: text)
        case .open(let u): url = u
        case .history(let entry): url = entry.url
        }
        if let url { onPick?(url) }
    }
}

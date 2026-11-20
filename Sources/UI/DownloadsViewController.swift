import UIKit
import QuickLook

/// Список загруженных файлов (папка Documents, она же «Файлы» → На iPhone → Kentik).
/// Нажатие — просмотр (Quick Look), смахивание — удалить, долгое нажатие — поделиться.
final class DownloadsViewController: UITableViewController, QLPreviewControllerDataSource {

    private var files: [URL] = []
    private var previewIndex = 0

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Загрузки"
        view.accessibilityIdentifier = "downloadsView"
        tableView.backgroundColor = Theme.background
        tableView.separatorColor = Theme.line
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "file")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        reload()
    }

    private func reload() {
        let dir = DownloadManager.directory
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        files = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        tableView.reloadData()
        if files.isEmpty {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "arrow.down.circle")
            config.text = "Загрузок нет"
            config.secondaryText = "Скачанные файлы появятся здесь и в приложении «Файлы» → Kentik."
            config.textProperties.color = Theme.text
            config.secondaryTextProperties.color = Theme.dim
            config.imageProperties.tintColor = Theme.violet
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { files.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "file", for: indexPath)
        let file = files[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = file.lastPathComponent
        content.textProperties.color = Theme.text
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        content.secondaryText = Self.sizeFormatter.string(fromByteCount: size)
        content.secondaryTextProperties.color = Theme.faint
        content.image = UIImage(systemName: "doc")
        content.imageProperties.tintColor = Theme.violet
        cell.contentConfiguration = content
        cell.backgroundColor = Theme.bar
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        previewIndex = indexPath.row
        let preview = QLPreviewController()
        preview.dataSource = self
        preview.currentPreviewItemIndex = indexPath.row
        present(preview, animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration? {
        let delete = UIContextualAction(style: .destructive, title: "Удалить") { [weak self] _, _, done in
            guard let self else { return done(false) }
            try? FileManager.default.removeItem(at: self.files[indexPath.row])
            self.reload()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        let file = files[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Поделиться", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = self?.view
                    self?.present(share, animated: true)
                },
            ])
        }
    }

    // MARK: - QLPreviewControllerDataSource

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { files.count }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        files[index] as NSURL
    }
}

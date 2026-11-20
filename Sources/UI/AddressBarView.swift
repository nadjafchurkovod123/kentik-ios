import UIKit

/// Верхняя панель: заголовок страницы, адресная строка и полоса загрузки.
final class AddressBarView: UIView {

    let titleLabel = UILabel()
    let textField = UITextField()
    let progressView = UIProgressView(progressViewStyle: .bar)
    private let iconView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.bar

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = Theme.dim
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityIdentifier = "pageTitle"

        textField.backgroundColor = Theme.field
        textField.textColor = Theme.text
        textField.tintColor = Theme.violet
        textField.font = .systemFont(ofSize: 16)
        textField.layer.cornerRadius = 12
        textField.layer.cornerCurve = .continuous
        textField.keyboardType = .webSearch
        textField.returnKeyType = .go
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartQuotesType = .no
        textField.smartDashesType = .no
        textField.clearButtonMode = .whileEditing
        textField.textContentType = .URL
        textField.accessibilityIdentifier = "addressBar"

        let iconHolder = UIView(frame: CGRect(x: 0, y: 0, width: 36, height: 40))
        iconView.frame = iconHolder.bounds
        iconView.contentMode = .center
        iconView.tintColor = Theme.dim
        iconHolder.addSubview(iconView)
        textField.leftView = iconHolder
        textField.leftViewMode = .always

        progressView.progressTintColor = Theme.violet
        progressView.trackTintColor = .clear
        progressView.accessibilityIdentifier = "progressBar"
        progressView.isHidden = true

        [titleLabel, textField, progressView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        let safe = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),

            textField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            textField.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            textField.heightAnchor.constraint(equalToConstant: 40),

            progressView.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 8),
            progressView.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),
            progressView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setIncognito(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    /// Инкогнито подсвечивается другим цветом панели и значком.
    func setIncognito(_ incognito: Bool) {
        backgroundColor = incognito ? Theme.barIncognito : Theme.bar
        iconView.image = UIImage(systemName: incognito ? "eye.slash" : "magnifyingglass")
        let placeholder = incognito ? "Инкогнито: поиск или адрес" : "Поиск или адрес"
        textField.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: Theme.dim]
        )
    }

    func setProgress(_ value: Double, loading: Bool) {
        if loading {
            progressView.isHidden = false
            progressView.setProgress(Float(max(value, 0.05)), animated: true)
        } else {
            progressView.setProgress(0, animated: false)
            progressView.isHidden = true
        }
    }
}

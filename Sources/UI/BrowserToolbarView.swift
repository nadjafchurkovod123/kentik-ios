import UIKit

/// Нижний ряд кнопок: назад, вперёд, новая вкладка, вкладки (со счётчиком), меню.
/// Все кнопки — в зоне большого пальца.
final class BrowserToolbarView: UIView {

    let backButton = UIButton(type: .system)
    let forwardButton = UIButton(type: .system)
    let newTabButton = UIButton(type: .system)
    let tabsButton = UIButton(type: .system)
    let menuButton = UIButton(type: .system)

    private let tabsFrame = UIView()
    private let tabsCount = UILabel()
    private let stack = UIStackView()

    static let height: CGFloat = 48

    override init(frame: CGRect) {
        super.init(frame: frame)

        configure(backButton, symbol: "chevron.backward", label: "Назад", id: "backButton")
        configure(forwardButton, symbol: "chevron.forward", label: "Вперёд", id: "forwardButton")
        configure(newTabButton, symbol: "plus", label: "Новая вкладка", id: "newTabButton")
        configure(menuButton, symbol: "ellipsis", label: "Меню", id: "menuButton")
        configure(tabsButton, symbol: nil, label: "Вкладки", id: "tabsButton")
        menuButton.showsMenuAsPrimaryAction = true

        // Значок вкладок — рамка с числом, как в Safari/Firefox.
        tabsFrame.isUserInteractionEnabled = false
        tabsFrame.layer.cornerRadius = 6
        tabsFrame.layer.cornerCurve = .continuous
        tabsFrame.layer.borderWidth = 2
        tabsCount.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        tabsCount.textAlignment = .center
        tabsCount.adjustsFontSizeToFitWidth = true
        tabsCount.minimumScaleFactor = 0.6
        tabsFrame.addSubview(tabsCount)
        tabsButton.addSubview(tabsFrame)
        tabsFrame.translatesAutoresizingMaskIntoConstraints = false
        tabsCount.translatesAutoresizingMaskIntoConstraints = false

        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        [backButton, forwardButton, newTabButton, tabsButton, menuButton].forEach(stack.addArrangedSubview)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),

            tabsFrame.centerXAnchor.constraint(equalTo: tabsButton.centerXAnchor),
            tabsFrame.centerYAnchor.constraint(equalTo: tabsButton.centerYAnchor),
            tabsFrame.widthAnchor.constraint(equalToConstant: 24),
            tabsFrame.heightAnchor.constraint(equalToConstant: 24),
            tabsCount.leadingAnchor.constraint(equalTo: tabsFrame.leadingAnchor, constant: 2),
            tabsCount.trailingAnchor.constraint(equalTo: tabsFrame.trailingAnchor, constant: -2),
            tabsCount.centerYAnchor.constraint(equalTo: tabsFrame.centerYAnchor),
        ])
        setTint(Theme.text, incognito: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    private func configure(_ button: UIButton, symbol: String?, label: String, id: String) {
        if let symbol {
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.setPreferredSymbolConfiguration(.init(pointSize: 19, weight: .medium), forImageIn: .normal)
        }
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
    }

    func setTint(_ color: UIColor, incognito: Bool) {
        [backButton, forwardButton, newTabButton, menuButton].forEach { $0.tintColor = color }
        tabsFrame.layer.borderColor = (incognito ? Theme.incognitoTint : color).cgColor
        tabsFrame.backgroundColor = incognito ? Theme.incognitoGradient[0].withAlphaComponent(0.6) : .clear
        tabsCount.textColor = incognito ? .white : color
        tabsButton.accessibilityIdentifier = "tabsButton"
        tabsButton.accessibilityHint = incognito ? "Инкогнито" : nil
    }

    func setTabCount(_ count: Int) {
        tabsCount.text = count > 99 ? "∞" : "\(count)"
        tabsButton.accessibilityValue = "\(count)"
    }
}

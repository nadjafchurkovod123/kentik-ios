import UIKit
import LocalAuthentication

extension Notification.Name {
    /// Замок инкогнито закрылся или открылся.
    static let incognitoLockChanged = Notification.Name("KentikIncognitoLockChanged")
}

/// Замок вкладок инкогнито по Face ID / коду-паролю (настройка, по умолчанию выключена).
/// Закрывается, когда приложение уходит в фон и есть вкладки инкогнито.
@MainActor
final class IncognitoLock {

    static let shared = IncognitoLock()

    private(set) var isLocked = false
    /// Идёт проверка Face ID (в это время сцена неактивна — не надо снова просить).
    private(set) var isAuthenticating = false

    var isEnabled: Bool { AppSettings.shared.incognitoFaceID }

    func lockIfNeeded(hasIncognitoTabs: Bool) {
        guard isEnabled, hasIncognitoTabs, !isLocked else { return }
        isLocked = true
        NotificationCenter.default.post(name: .incognitoLockChanged, object: self)
    }

    /// Вкладок инкогнито не осталось — замок не нужен.
    func reset() {
        guard isLocked else { return }
        isLocked = false
        NotificationCenter.default.post(name: .incognitoLockChanged, object: self)
    }

    func unlock(completion: @escaping @MainActor (Bool) -> Void) {
        guard isLocked else {
            completion(true)
            return
        }
        guard !isAuthenticating else { return }
        Self.authenticate(reason: "Открыть вкладки инкогнито") { [weak self] ok in
            guard let self else { return }
            if ok {
                self.isLocked = false
                NotificationCenter.default.post(name: .incognitoLockChanged, object: self)
            }
            completion(ok)
        }
    }

    /// Проверка владельца (Face ID, при неудаче — код-пароль). Если на устройстве нет
    /// ни Face ID, ни кода-пароля, защищать нечем — считаем проверку пройденной.
    static func authenticate(reason: String, completion: @escaping @MainActor (Bool) -> Void) {
        if TestHooks.fakeAuth {
            fakeAuthenticate(reason: reason, completion: completion)
            return
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(true)
            return
        }
        shared.isAuthenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            Task { @MainActor in
                IncognitoLock.shared.isAuthenticating = false
                completion(ok)
            }
        }
    }

    /// Только для UI-тестов (-KentikFakeAuth): запрос «Разрешить / Отменить» вместо Face ID,
    /// поверх всего, что сейчас на экране, — как настоящий запрос Face ID.
    private static func fakeAuthenticate(reason: String, completion: @escaping @MainActor (Bool) -> Void) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        guard var top = window?.rootViewController else {
            completion(false)
            return
        }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        shared.isAuthenticating = true
        let finish: @MainActor (Bool) -> Void = { ok in
            IncognitoLock.shared.isAuthenticating = false
            completion(ok)
        }
        let alert = UIAlertController(title: "Face ID (тест)", message: reason, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отменить", style: .cancel) { _ in
            MainActor.assumeIsolated { finish(false) }
        })
        alert.addAction(UIAlertAction(title: "Разрешить", style: .default) { _ in
            MainActor.assumeIsolated { finish(true) }
        })
        top.present(alert, animated: true)
    }
}

/// Экран замка поверх содержимого инкогнито.
final class IncognitoLockView: UIView {

    var onUnlock: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.incognitoBackground
        accessibilityIdentifier = "incognitoLock"

        let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
        icon.tintColor = Theme.violet
        icon.preferredSymbolConfiguration = .init(pointSize: 44, weight: .semibold)
        let title = UILabel()
        title.text = "Вкладки инкогнито заблокированы"
        title.font = .systemFont(ofSize: 18, weight: .bold)
        title.textColor = Theme.text
        title.textAlignment = .center
        title.numberOfLines = 0

        var config = UIButton.Configuration.filled()
        config.title = "Разблокировать"
        config.image = UIImage(systemName: "faceid")
        config.imagePadding = 8
        config.baseBackgroundColor = Theme.violet
        config.baseForegroundColor = Theme.background
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 22)
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = "unlockIncognito"
        button.addTarget(self, action: #selector(unlockTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, title, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }

    @objc private func unlockTapped() { onUnlock?() }
}

/// Шторка для переключателя приложений: прячет содержимое инкогнито на снимке.
final class PrivacyCoverView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.incognitoBackground
        accessibilityIdentifier = "privacyCover"

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blur.frame = bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blur)

        let icon = UIImageView(image: UIImage(systemName: "eye.slash.fill"))
        icon.tintColor = Theme.violet
        icon.preferredSymbolConfiguration = .init(pointSize: 48, weight: .semibold)
        let label = UILabel()
        label.text = "Kentik · инкогнито"
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textColor = Theme.text
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не используется")
    }
}

/// Снимки вкладок для переключателя. Только в памяти; снимки инкогнито исчезают
/// вместе с вкладками.
@MainActor
final class SnapshotCache {

    static let shared = SnapshotCache()

    private var images: [UUID: UIImage] = [:]

    func image(for tab: Tab) -> UIImage? { images[tab.id] }

    func set(_ image: UIImage?, for tab: Tab) {
        images[tab.id] = image
    }

    /// Убрать снимки закрытых вкладок.
    func prune(keeping tabs: [Tab]) {
        let alive = Set(tabs.map(\.id))
        images = images.filter { alive.contains($0.key) }
    }
}

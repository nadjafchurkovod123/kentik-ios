import UIKit
import LocalAuthentication

extension Notification.Name {
    /// Замок инкогнито закрылся или открылся.
    static let incognitoLockChanged = Notification.Name("KentikIncognitoLockChanged")
}

/// Замок инкогнито по Face ID / коду-паролю (настройка «Face ID для инкогнито», по умолчанию
/// включена).
///
/// Инкогнито — режим, в который входят через Face ID:
///  * при запуске приложения инкогнито заперто;
///  * запирается, когда приложение уходит в фон;
///  * запирается, если пользователь ушёл из инкогнито на обычные вкладки дольше чем на
///    `grace` секунд (30 с): короткий заход в обычную вкладку не требует Face ID снова;
///  * вход — вкладка инкогнито на экране, раздел «Инкогнито» в переключателе, новая вкладка
///    инкогнито, «Открыть в инкогнито» из меню ссылки, возвращение из фона — сначала Face ID;
///  * пока пользователь в инкогнито, повторно не спрашивает.
/// На устройстве без кода-пароля защищать нечем — замок не запирается (как раньше).
@MainActor
final class IncognitoLock {

    static let shared = IncognitoLock()

    /// Сколько секунд можно пробыть на обычных вкладках, не запирая инкогнито.
    static var grace: TimeInterval { TestHooks.incognitoGrace ?? 30 }

    private(set) var isLocked: Bool
    /// Идёт проверка Face ID (в это время сцена неактивна — не надо снова просить).
    private(set) var isAuthenticating = false
    /// Когда пользователь ушёл из (открытого) инкогнито на обычные вкладки; nil — он в инкогнито
    /// или инкогнито заперто.
    private(set) var leftAt: Date?
    /// Когда последний раз показали запрос Face ID.
    private(set) var lastPromptAt: Date?

    private let enabledProvider: @MainActor () -> Bool

    /// enabled — для модульных тестов (по умолчанию настройка + наличие Face ID / кода-пароля).
    init(enabled: (@MainActor () -> Bool)? = nil) {
        let provider = enabled ?? { IncognitoLock.enabledNow }
        enabledProvider = provider
        isLocked = provider()
    }

    var isEnabled: Bool { enabledProvider() }

    /// Настройка включена и есть чем проверять (Face ID / код-пароль; в UI-тестах — тестовый запрос).
    private static var enabledNow: Bool {
        guard AppSettings.shared.incognitoFaceID else { return false }
        if TestHooks.fakeAuth { return true }
        // В UI-тестах настоящий Face ID не используется (им нельзя управлять из теста): без
        // тестового запроса замок выключен.
        if TestHooks.isUITest { return false }
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    private func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        leftAt = nil
        NotificationCenter.default.post(name: .incognitoLockChanged, object: self)
    }

    /// Запереть (уход в фон). Вкладки инкогнито для этого не нужны: следующий вход в инкогнито
    /// тоже начнётся с Face ID.
    func lock() {
        guard isEnabled else { return }
        setLocked(true)
    }

    /// Совместимость с прежним вызовом из SceneDelegate.
    func lockIfNeeded(hasIncognitoTabs: Bool) {
        lock()
    }

    /// Настройку выключили — замок не нужен.
    func reset() {
        setLocked(false)
    }

    /// Запереть, если пользователь слишком долго был на обычных вкладках.
    func lockIfStale(now: Date = Date()) {
        guard !isLocked, let leftAt, now.timeIntervalSince(leftAt) > Self.grace else { return }
        lock()
    }

    /// Что сейчас на экране: инкогнито (вкладка или раздел переключателя) или обычные вкладки.
    /// Вход в инкогнито после долгого отсутствия запирает его (до показа содержимого).
    func noteVisible(incognito: Bool, now: Date = Date()) {
        if incognito {
            lockIfStale(now: now)
            if !isLocked { leftAt = nil }
        } else if !isLocked, leftAt == nil {
            leftAt = now
        }
    }

    /// Войти в инкогнито (новая вкладка, «Открыть в инкогнито», раздел переключателя):
    /// если заперто — сначала Face ID. completion(true) — можно показывать инкогнито.
    func requestEntry(completion: @escaping @MainActor (Bool) -> Void) {
        lockIfStale()
        unlock { [weak self] ok in
            if ok { self?.leftAt = nil }
            completion(ok)
        }
    }

    func unlock(completion: @escaping @MainActor (Bool) -> Void) {
        lockIfStale()
        guard isLocked else {
            completion(true)
            return
        }
        guard !isAuthenticating else { return }
        Self.authenticate(reason: "Открыть вкладки инкогнито") { [weak self] ok in
            guard let self else { return }
            if ok { self.setLocked(false) }
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
        shared.lastPromptAt = Date()
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
        // Окно браузера, а не ключевое: пока WebKit закрывает «картинку в картинке» или полноэкранный
        // режим, ключевым может быть его служебное окно (или никакое).
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        let window = windows.first { $0.rootViewController is BrowserViewController }
            ?? windows.first { $0.isKeyWindow }
        guard var top = window?.rootViewController else {
            completion(false)
            return
        }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        shared.isAuthenticating = true
        shared.lastPromptAt = Date()
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

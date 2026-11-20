import UIKit

/// Единственная сцена: окно с BrowserViewController. Тема всегда тёмная.
/// Здесь же: ссылки kentik://, шторка инкогнито для переключателя приложений,
/// замок инкогнито и сохранение вкладок при уходе в фон.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private(set) var tabManager = TabManager()
    private var browser: BrowserViewController?
    private var privacyCover: PrivacyCoverView?
    private var wasInBackground = false

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = .dark
        window.tintColor = Theme.violet
        window.backgroundColor = Theme.background
        let browser = BrowserViewController(tabManager: tabManager)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        self.window = window
        self.browser = browser

        handle(connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handle(URLContexts)
    }

    private func handle(_ contexts: Set<UIOpenURLContext>) {
        for context in contexts {
            if let url = KentikURL.target(from: context.url) {
                browser?.openExternal(url)
            }
        }
    }

    // MARK: - Жизненный цикл

    func sceneWillResignActive(_ scene: UIScene) {
        // Снимок для переключателя приложений делается после этого вызова — прячем инкогнито.
        if browser?.isShowingIncognitoContent == true {
            showPrivacyCover()
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        hidePrivacyCover()
        browser?.didBecomeActive()
        if wasInBackground {
            wasInBackground = false
            browser?.unlockIfNeeded()
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        wasInBackground = true
        browser?.saveState()
        IncognitoLock.shared.lockIfNeeded(hasIncognitoTabs: tabManager.hasIncognitoTabs)
        if browser?.isShowingIncognitoContent == true, privacyCover == nil {
            showPrivacyCover()
        }
    }

    private func showPrivacyCover() {
        guard let window, privacyCover == nil else { return }
        let cover = PrivacyCoverView(frame: window.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(cover)
        privacyCover = cover
    }

    private func hidePrivacyCover() {
        guard let cover = privacyCover else { return }
        privacyCover = nil
        UIView.animate(withDuration: Theme.fast, animations: { cover.alpha = 0 }, completion: { _ in
            cover.removeFromSuperview()
        })
    }
}

/// Разбор ссылок kentik://
///  kentik://open?url=https%3A%2F%2Fexample.com — открыть адрес;
///  kentik://example.com/path или kentik:https://… — то же, короче.
enum KentikURL {
    static func target(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == "kentik" else { return nil }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.host?.lowercased() == "open",
           let value = components.queryItems?.first(where: { $0.name == "url" })?.value {
            return AddressParser.url(from: value)
        }
        var rest = url.absoluteString
        if let range = rest.range(of: "kentik:", options: [.caseInsensitive, .anchored]) {
            rest.removeSubrange(range)
        }
        if rest.hasPrefix("//") { rest.removeFirst(2) }
        rest = rest.removingPercentEncoding ?? rest
        return AddressParser.url(from: rest)
    }
}

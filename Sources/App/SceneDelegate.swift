import UIKit

/// Единственная сцена: окно с BrowserViewController. Тема всегда тёмная.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private(set) var tabManager = TabManager()

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
        window.rootViewController = BrowserViewController(tabManager: tabManager)
        window.makeKeyAndVisible()
        self.window = window
    }
}

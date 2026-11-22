import UIKit

/// Точка входа приложения. Вся работа с окнами — в SceneDelegate.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        TestHooks.prepareFreshStateIfNeeded()
        if TestHooks.incognitoFaceID { AppSettings.shared.incognitoFaceID = true }
        if TestHooks.incognitoFaceIDOff { AppSettings.shared.incognitoFaceID = false }
        AppSettings.shared.applySearchEngine()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}

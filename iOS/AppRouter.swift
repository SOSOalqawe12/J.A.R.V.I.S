import SwiftUI
import UIKit
import UserNotifications

/// Routes requests from Siri, quick actions, URLs and "Share to JARVIS" into the UI.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    enum Action: Equatable {
        case voice(String?)
        case newChat
        case briefing
        case scan
        case ask(String)
        case attach(URL)
        case files
    }

    @Published var pending: Action?

    func perform(_ action: Action) { pending = action }
}

enum QuickActions {
    @MainActor
    static func handle(_ item: UIApplicationShortcutItem) {
        switch item.type {
        case "voice": AppRouter.shared.perform(.voice(nil))
        case "newchat": AppRouter.shared.perform(.newChat)
        case "briefing": AppRouter.shared.perform(.briefing)
        case "scan": AppRouter.shared.perform(.scan)
        default: break
        }
    }
}

final class JarvisAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem {
            Task { @MainActor in QuickActions.handle(item) }
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = JarvisSceneDelegate.self
        return configuration
    }
}

final class JarvisSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in QuickActions.handle(shortcutItem) }
        completionHandler(true)
    }
}

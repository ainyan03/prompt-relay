import SwiftUI
import UserNotifications

@main
struct PromptRelayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                appDelegate.reregisterTokenIfNeeded()
                appDelegate.cleanupStaleNotifications()
            }
        }
    }
}

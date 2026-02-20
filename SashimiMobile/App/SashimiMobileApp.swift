import SwiftUI
import SwiftData

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadManager.shared.setBackgroundCompletionHandler(completionHandler)
    }
}

@main
struct SashimiMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var sessionManager = SessionManager.shared

    let modelContainer: ModelContainer

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: DownloadedItem.self, DownloadedSubtitle.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        self.modelContainer = container
        DownloadManager.shared.setModelContainer(container)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionManager)
        }
        .modelContainer(modelContainer)
    }
}

struct ContentView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        Group {
            if sessionManager.isAuthenticated {
                MainNavigationView()
                    .task {
                        // Sync any offline playback progress back to server
                        await DownloadManager.shared.syncPendingProgress()
                    }
            } else {
                MobileAuthView()
            }
        }
        .task {
            await sessionManager.restoreSession()
        }
    }
}

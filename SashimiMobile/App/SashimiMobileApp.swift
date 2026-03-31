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
    @StateObject private var serverManager = ServerManager.shared

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
                .environmentObject(serverManager)
        }
        .modelContainer(modelContainer)
    }
}

struct ContentView: View {
    @EnvironmentObject var serverManager: ServerManager
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if serverManager.isAuthenticated {
                Group {
                    if sizeClass == .compact {
                        PhoneTabView()
                    } else {
                        MainNavigationView()
                    }
                }
                .task {
                    await DownloadManager.shared.syncPendingProgress()
                }
            } else {
                MobileAuthView()
            }
        }
    }
}

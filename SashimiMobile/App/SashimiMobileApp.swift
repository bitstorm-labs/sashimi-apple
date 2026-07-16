import SwiftUI
import SwiftData
import UIKit

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

    // Pick the layout by DEVICE TYPE (stable), not horizontalSizeClass (transient).
    // The size class flips .compact -> .regular when an iPhone Plus/Pro Max rotates
    // to landscape, which would swap the entire root view (PhoneTabView <-> the iPad
    // layout) and tear down its subtree — dismissing an active fullScreenCover video
    // player. A phone stays on the phone UI in landscape; iPad always uses the iPad UI.
    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        Group {
            if sessionManager.isAuthenticated {
                // Rebuild the navigation hierarchy when the active server
                // changes so every view reloads against the new server.
                Group {
                    if isPad {
                        MainNavigationView()
                    } else {
                        PhoneTabView()
                    }
                }
                .id(sessionManager.activeServerId)
                .task {
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

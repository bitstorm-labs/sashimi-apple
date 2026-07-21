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

    // sashimi:// deep links (play/{id}, item/{id}) — mirrors the tvOS handler.
    // Links arriving before session restore completes are stashed and replayed
    // once authentication flips; latest link wins.
    @State private var deepLinkDestination: DeepLinkDestination?
    @State private var pendingDeepLink: DeepLink?
    @State private var deepLinkTask: Task<Void, Never>?

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
                // Re-auth a saved server whose session expired: tapping it in
                // the switcher raises reauthServer; present a prefilled login.
                .sheet(item: $sessionManager.reauthServer) { server in
                    NavigationStack {
                        MobileAuthView(
                            onCancel: { sessionManager.reauthServer = nil },
                            onComplete: { sessionManager.reauthServer = nil },
                            prefillServerURL: server.url
                        )
                        .navigationBarTitleDisplayMode(.inline)
                    }
                    .onDisappear {
                        Task { await sessionManager.restoreActiveClient() }
                    }
                }
            } else {
                NavigationStack {
                    MobileAuthView()
                }
            }
        }
        .task {
            await sessionManager.restoreSession()
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onChange(of: sessionManager.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated {
                if let link = pendingDeepLink {
                    pendingDeepLink = nil
                    resolveDeepLink(link)
                }
            } else {
                pendingDeepLink = nil
                deepLinkTask?.cancel()
                deepLinkDestination = nil
            }
        }
        .fullScreenCover(item: $deepLinkDestination) { destination in
            switch destination {
            case .play(let item):
                MobilePlayerView(item: item)
            case .detail(let item):
                NavigationStack {
                    AdaptiveDetailView(item: item)
                        // Modal root has no back button and fullScreenCover has
                        // no swipe-to-dismiss — without this the user is stuck.
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Done") { deepLinkDestination = nil }
                            }
                        }
                }
            }
        }
    }

    @MainActor
    private func handleDeepLink(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        guard sessionManager.isAuthenticated else {
            pendingDeepLink = link
            return
        }
        resolveDeepLink(link)
    }

    @MainActor
    private func resolveDeepLink(_ link: DeepLink) {
        // Last link wins: cancel any in-flight resolution.
        deepLinkTask?.cancel()
        deepLinkTask = Task {
            guard let item = try? await JellyfinClient.shared.getItem(itemId: link.itemId),
                  !Task.isCancelled else { return }
            switch link.action {
            case .play:
                deepLinkDestination = .play(item)
            case .item:
                deepLinkDestination = .detail(item)
            }
        }
    }
}

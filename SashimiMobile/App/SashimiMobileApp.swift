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
    @Environment(\.scenePhase) private var scenePhase

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
        SashimiImagePipeline.configureCaches()
        SashimiImagePipeline.install()
#if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            SashimiAppShortcuts.updateAppShortcutParameters()
        }
#endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionManager)
        }
        .modelContainer(modelContainer)
        // Mirrors SashimiApp (tvOS): background/lock is a scene-phase change,
        // not a view teardown, so the theme has to be stopped from here
        // rather than relying on a detail screen's `onDisappear`.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                ThemeSongPlayer.shared.appDidBackground()
            }
            if newPhase == .active {
                Task { await PlaybackReportDelivery.shared.flush() }
                if #available(iOS 18.0, *) {
                    SashimiMediaSpotlightIndexer.shared.refresh()
                }
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.scenePhase) private var scenePhase

    // sashimi:// deep links (play/{id}, item/{id}) — mirrors the tvOS handler.
    // Links arriving before session restore completes are stashed and replayed
    // once authentication flips; latest link wins.
    @State private var deepLinkDestination: DeepLinkDestination?
    @State private var pendingDeepLink: DeepLink?
    @State private var deepLinkTask: Task<Void, Never>?
    @ObservedObject private var intentCoordinator = SashimiIntentCoordinator.shared
    @State private var intentSearchRequest: SashimiIntentCoordinator.SearchRequest?
    @State private var intentMediaEntity: SashimiMediaEntity?
    @State private var intentPlaybackEntity: SashimiMediaEntity?
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

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
                        MainNavigationView(
                            searchRequest: intentSearchRequest,
                            onSearchRequestConsumed: consumeIntentSearchRequest
                        )
                    } else {
                        PhoneTabView(
                            searchRequest: intentSearchRequest,
                            onSearchRequestConsumed: consumeIntentSearchRequest
                        )
                    }
                }
                .id(sessionManager.activeSessionIdentity)
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
                            prefillServerURL: server.url,
                            prefillUsername: server.username
                        )
                        .navigationBarTitleDisplayMode(.inline)
                    }
                    .onDisappear {
                        Task { await sessionManager.restoreActiveClient() }
                    }
                }
            } else {
                NavigationStack {
                    MobileAuthView(
                        prefillServerURL: sessionManager.reauthServer?.url,
                        prefillUsername: sessionManager.reauthServer?.username
                    )
                    .id(sessionManager.reauthServer?.id)
                }
            }
        }
        .task {
            await sessionManager.restoreSession()
            if #available(iOS 18.0, *) {
                SashimiMediaSpotlightIndexer.shared.refresh()
            }
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onChange(of: sessionManager.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated {
                if #available(iOS 18.0, *) {
                    SashimiMediaSpotlightIndexer.shared.refresh()
                }
                if let link = pendingDeepLink {
                    pendingDeepLink = nil
                    resolveDeepLink(link)
                }
                handleIntentRoute(intentCoordinator.route)
            } else {
                if #available(iOS 18.0, *) {
                    SashimiMediaSpotlightIndexer.shared.clear()
                }
                pendingDeepLink = nil
                deepLinkTask?.cancel()
                deepLinkDestination = nil
            }
        }
        .onChange(of: sessionManager.servers) { _, _ in
            if #available(iOS 18.0, *) {
                SashimiMediaSpotlightIndexer.shared.refresh()
            }
        }
        .onChange(of: intentCoordinator.route) { _, route in
            handleIntentRoute(route)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await PlaybackReportDelivery.shared.flush() }
            // Siri or Shortcuts may have written a route while Sashimi was
            // inactive in another process. Refresh before handling the active
            // scene so card taps work without requiring a cold launch.
            intentCoordinator.reloadPersistedRoute()
            handleIntentRoute(intentCoordinator.route)
        }
        .onChange(of: networkMonitor.isConnected) { _, isConnected in
            guard isConnected else { return }
            Task { await PlaybackReportDelivery.shared.flush() }
        }
        .onChange(of: intentPlaybackEntity) { oldEntity, newEntity in
            guard newEntity == nil, let oldEntity else { return }
            // SwiftUI may clear the binding before invoking fullScreenCover's
            // onDismiss closure. Consume a still-pending handoff in either
            // ordering so a user-cancelled cold launch is not re-presented.
            intentCoordinator.cancelPlayback(for: oldEntity)
        }
        .onAppear {
            // An App Intent may finish while the app scene is still mounting;
            // process a route that already exists when ContentView appears.
            intentCoordinator.reloadPersistedRoute()
            handleIntentRoute(intentCoordinator.route)
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
        .fullScreenCover(
            item: $intentMediaEntity,
            onDismiss: { intentMediaEntity = nil },
            content: { entity in
                NavigationStack {
                    SashimiIntentMediaDestinationView(entity: entity)
                }
            }
        )
        .fullScreenCover(
            item: $intentPlaybackEntity,
            onDismiss: {
                if let entity = intentPlaybackEntity {
                    intentCoordinator.cancelPlayback(for: entity)
                }
                intentPlaybackEntity = nil
            },
            content: { entity in
                NavigationStack {
                    SashimiIntentPlaybackDestinationView(entity: entity)
                }
            }
        )
    }

    @MainActor
    private func handleIntentRoute(_ route: SashimiIntentCoordinator.Route?) {
        guard sessionManager.isAuthenticated, let route else { return }

        switch route {
        case .search(let request):
            intentSearchRequest = request
        case .open(let request):
            presentIntentMediaEntity(request.entity)
            intentCoordinator.consume(route)
        case .play(let request):
            intentPlaybackEntity = request.entity
        }
    }

    @MainActor
    private func presentIntentMediaEntity(_ entity: SashimiMediaEntity) {
        guard intentMediaEntity?.id != entity.id else { return }
        guard intentMediaEntity != nil else {
            intentMediaEntity = entity
            return
        }

        // A second card tap can arrive while the first intent cover is still
        // presented. Reset the item for one run-loop turn so fullScreenCover
        // replaces the old detail route instead of keeping stale content.
        intentMediaEntity = nil
        Task { @MainActor in
            await Task.yield()
            intentMediaEntity = entity
        }
    }

    @MainActor
    private func consumeIntentSearchRequest(_ id: UUID) {
        guard intentSearchRequest?.id == id else { return }
        intentSearchRequest = nil
        intentCoordinator.consumeSearchRequest(id: id)
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

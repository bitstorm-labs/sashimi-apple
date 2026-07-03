import SwiftUI
import AVFoundation
import os

private let logger = Logger(subsystem: "com.sashimi.app", category: "App")

@main
struct SashimiApp: App {
    @StateObject private var sessionManager = SessionManager.shared

    init() {
        configureAudioSession()
        resetAppIconToDefault()
    }

    private func resetAppIconToDefault() {
        // Reset to default icon in case a previous alternate icon attempt left it broken
        if UIApplication.shared.alternateIconName != nil {
            UIApplication.shared.setAlternateIconName(nil) { _ in }
        }
    }

    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
        } catch {
            logger.error("Failed to configure audio session: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionManager)
                .toastOverlay()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var sessionManager: SessionManager

    // Destination resolved from a sashimi:// deep link (Top Shelf play/display actions)
    @State private var deepLinkDestination: DeepLinkDestination?
    // Link received while signed out — on a cold launch, onOpenURL usually
    // fires before the async session restore completes, so the link is
    // stashed here and replayed once authentication flips. Latest link wins.
    @State private var pendingDeepLink: DeepLink?
    @State private var deepLinkTask: Task<Void, Never>?

    var body: some View {
        Group {
            if sessionManager.isAuthenticated {
                MainTabView()
            } else {
                ServerConnectionView()
            }
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
                // Signed out: a stashed link belongs to the old session, and
                // nothing deep-linked should stay presented over the login UI.
                pendingDeepLink = nil
                deepLinkTask?.cancel()
                deepLinkDestination = nil
            }
        }
        .fullScreenCover(item: $deepLinkDestination) { destination in
            switch destination {
            case .play(let item):
                PlayerView(item: item, startFromBeginning: false)
            case .detail(let item):
                MediaDetailView(item: item)
            }
        }
    }

    @MainActor
    private func handleDeepLink(_ url: URL) {
        guard let link = DeepLink(url: url) else {
            logger.debug("Ignoring malformed deep link: \(url.absoluteString)")
            return
        }
        guard sessionManager.isAuthenticated else {
            logger.debug("Deferring deep link until session restore completes")
            pendingDeepLink = link
            return
        }
        resolveDeepLink(link)
    }

    @MainActor
    private func resolveDeepLink(_ link: DeepLink) {
        // Last tap wins: cancel any in-flight resolution so a slow earlier
        // fetch can't clobber this one after it completes.
        deepLinkTask?.cancel()
        deepLinkTask = Task {
            do {
                let item = try await JellyfinClient.shared.getItem(itemId: link.itemId)
                guard !Task.isCancelled else { return }
                switch link.action {
                case .play:
                    deepLinkDestination = .play(item)
                case .item:
                    deepLinkDestination = .detail(item)
                }
            } catch {
                guard !Task.isCancelled else { return }
                // The user explicitly tapped this item, so a silent failure
                // reads as a dead button — tell them.
                logger.error("Failed to load deep-linked item \(link.itemId, privacy: .public): \(error.localizedDescription)")
                ToastManager.shared.show("Couldn't open item")
            }
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(0)

            LibraryView(onBackAtRoot: { selectedTab = 0 })
                .tabItem {
                    Label("Library", systemImage: "square.grid.2x2")
                }
                .tag(1)

            SearchView(onBackAtRoot: { selectedTab = 0 })
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(2)

            SettingsView(onBackAtRoot: { selectedTab = 0 })
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(3)
        }
        .onExitCommand(perform: exitCommandAction)
    }

    /// Menu/back button handling. Returns nil on the Home tab so the press
    /// is left unhandled and propagates to the system, which suspends the
    /// app and returns to the tvOS home screen. The previous two-press flow
    /// called exit(0), which Apple prohibits (programmatic termination) —
    /// see issue #174.
    private var exitCommandAction: (() -> Void)? {
        if selectedTab != 0 {
            // Other tabs: go to Home
            return { selectedTab = 0 }
        }
        // Home tab: let the system handle Menu (leave the app)
        return nil
    }
}

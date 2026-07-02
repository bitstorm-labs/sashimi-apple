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

    var body: some View {
        Group {
            if sessionManager.isAuthenticated {
                MainTabView()
            } else {
                ServerConnectionView()
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

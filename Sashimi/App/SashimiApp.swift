import SwiftUI
import AVFoundation
import os

private let logger = Logger(subsystem: "com.sashimi.app", category: "App")

@main
struct SashimiApp: App {
    @StateObject private var sessionManager = SessionManager.shared

    init() {
        configureAudioSession()
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
    @State private var homeViewResetTrigger = false
    @State private var isAtDefaultState = true

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(resetTrigger: $homeViewResetTrigger, isAtDefaultState: $isAtDefaultState)
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

            ProfileMenuView(onBackAtRoot: { selectedTab = 0 })
                .tabItem {
                    Label(sessionManager.currentUser?.name ?? "Profile", systemImage: "person.circle")
                }
                .tag(3)
        }
        .ifCondition(selectedTab != 0 || !isAtDefaultState) { view in
            view.onExitCommand {
                if selectedTab == 0 {
                    // Home tab not at top: scroll to top
                    homeViewResetTrigger.toggle()
                } else {
                    // Non-home tabs: go to home
                    selectedTab = 0
                }
            }
        }
    }
}

extension View {
    @ViewBuilder
    func ifCondition<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

struct ProfileMenuView: View {
    var onBackAtRoot: (() -> Void)?
    @EnvironmentObject private var sessionManager: SessionManager
    @State private var showingLogoutConfirmation = false
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section {
                    HStack(spacing: 20) {
                        if let userId = sessionManager.currentUser?.id,
                           let imageURL = JellyfinClient.shared.userImageURL(userId: userId) {
                            AsyncImage(url: imageURL) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Image(systemName: "person.circle.fill")
                                    .resizable()
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 80, height: 80)
                            .clipShape(Circle())
                        } else {
                            Image(systemName: "person.circle.fill")
                                .resizable()
                                .frame(width: 80, height: 80)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            if let userName = sessionManager.currentUser?.name {
                                Text(userName)
                                    .font(.title3)
                                    .fontWeight(.semibold)
                            }

                            if let serverURL = sessionManager.serverURL {
                                Text(serverURL.host ?? serverURL.absoluteString)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Home Screen") {
                    NavigationLink("Row Order") {
                        HomeScreenSettingsView()
                    }
                }

                Section("Playback") {
                    NavigationLink("Video Quality") {
                        VideoQualitySettingsView()
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Build", value: "1")
                }

                Section {
                    Button(role: .destructive) {
                        showingLogoutConfirmation = true
                    } label: {
                        Text("Sign Out")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .confirmationDialog(
                "Sign Out",
                isPresented: $showingLogoutConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    sessionManager.logout()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to sign out?")
            }
        }
        .onExitCommand {
            if navigationPath.isEmpty {
                onBackAtRoot?()
            } else {
                navigationPath.removeLast()
            }
        }
    }
}

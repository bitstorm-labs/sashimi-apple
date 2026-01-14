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
    @State private var lastExitPressTime: Date?
    private let exitTimeout: TimeInterval = 2.5

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

            SettingsView(onBackAtRoot: { selectedTab = 0 })
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(3)
        }
        .onExitCommand {
            // Handle back/menu button press
            if selectedTab == 0 {
                if !isAtDefaultState {
                    // Home tab not at default: scroll to top
                    homeViewResetTrigger.toggle()
                } else {
                    // At default state on Home: two-press to exit
                    handleExitAttempt()
                }
            } else {
                // Other tabs: go to Home
                selectedTab = 0
            }
        }
    }

    private func handleExitAttempt() {
        let now = Date()

        if let lastPress = lastExitPressTime,
           now.timeIntervalSince(lastPress) < exitTimeout {
            // Second press within timeout - allow exit
            // Clear the toast and exit
            ToastManager.shared.dismiss()
            // System will handle the exit on the next unhandled onExitCommand
            lastExitPressTime = nil
            exit(0)
        } else {
            // First press - show hint and start timeout
            lastExitPressTime = now
            ToastManager.shared.show(
                "Press Menu again to exit",
                type: .info,
                duration: exitTimeout
            )
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

// MARK: - Profile Menu View

enum ProfileDestination: Hashable {
    case homeScreen
    case playback
    case parentalControls
    case certificates
}

struct ProfileMenuView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sessionManager: SessionManager
    @State private var showingLogoutConfirmation = false
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [SashimiTheme.background, Color.black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 50) {
                        // User Profile Header
                        ProfileHeaderView()
                            .padding(.top, 60)

                        // Settings Grid
                        VStack(alignment: .leading, spacing: 30) {
                            Text("Settings")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundStyle(SashimiTheme.textPrimary)
                                .padding(.horizontal, 80)

                            LazyVGrid(columns: [
                                GridItem(.flexible(), spacing: 30),
                                GridItem(.flexible(), spacing: 30),
                                GridItem(.flexible(), spacing: 30),
                                GridItem(.flexible(), spacing: 30)
                            ], spacing: 30) {
                                ProfileSettingsCard(
                                    icon: "house",
                                    title: "Home Screen",
                                    subtitle: "Customize rows",
                                    color: .blue
                                ) {
                                    navigationPath.append(ProfileDestination.homeScreen)
                                }

                                ProfileSettingsCard(
                                    icon: "play.circle",
                                    title: "Playback",
                                    subtitle: "Quality & behavior",
                                    color: .purple
                                ) {
                                    navigationPath.append(ProfileDestination.playback)
                                }

                                ProfileSettingsCard(
                                    icon: "lock.shield",
                                    title: "Parental",
                                    subtitle: "PIN & restrictions",
                                    color: .orange
                                ) {
                                    navigationPath.append(ProfileDestination.parentalControls)
                                }

                                ProfileSettingsCard(
                                    icon: "checkmark.shield",
                                    title: "Security",
                                    subtitle: "Certificates",
                                    color: .green
                                ) {
                                    navigationPath.append(ProfileDestination.certificates)
                                }
                            }
                            .padding(.horizontal, 80)
                        }

                        // App Info & Sign Out
                        VStack(spacing: 30) {
                            // App info
                            HStack(spacing: 40) {
                                AppInfoItem(label: "Version", value: "1.0.0")
                                AppInfoItem(label: "Build", value: "1")
                            }
                            .padding(.vertical, 20)

                            // Sign out button
                            SignOutButton {
                                showingLogoutConfirmation = true
                            }
                        }
                        .padding(.top, 20)
                        .padding(.bottom, 80)
                    }
                }
            }
            .navigationDestination(for: ProfileDestination.self) { destination in
                switch destination {
                case .homeScreen:
                    HomeScreenSettingsView()
                case .playback:
                    PlaybackSettingsView()
                case .parentalControls:
                    ParentalControlsView()
                case .certificates:
                    CertificateSettingsView()
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
            .onExitCommand {
                // Handle back/menu button
                if navigationPath.isEmpty {
                    dismiss()
                } else {
                    navigationPath.removeLast()
                }
            }
        }
    }
}

// MARK: - Profile Header

struct ProfileHeaderView: View {
    @EnvironmentObject private var sessionManager: SessionManager

    var body: some View {
        VStack(spacing: 20) {
            // Avatar
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [SashimiTheme.accent, SashimiTheme.accent.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 140, height: 140)

                if let userId = sessionManager.currentUser?.id,
                   let imageURL = JellyfinClient.shared.userImageURL(userId: userId) {
                    AsyncImage(url: imageURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "person.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 130, height: 130)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.white)
                }
            }
            .shadow(color: SashimiTheme.accent.opacity(0.4), radius: 20)

            // User name
            if let userName = sessionManager.currentUser?.name {
                Text(userName)
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(SashimiTheme.textPrimary)
            }

            // Server info
            if let serverURL = sessionManager.serverURL {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 16))
                    Text(serverURL.host ?? serverURL.absoluteString)
                        .font(.system(size: 20))
                }
                .foregroundStyle(SashimiTheme.textSecondary)
            }
        }
    }
}

// MARK: - Settings Card

struct ProfileSettingsCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(color.opacity(isFocused ? 0.3 : 0.15))
                        .frame(width: 70, height: 70)

                    Image(systemName: icon)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(isFocused ? .white : color)
                }

                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(SashimiTheme.textPrimary)

                    Text(subtitle)
                        .font(.system(size: 16))
                        .foregroundStyle(SashimiTheme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(SashimiTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isFocused ? SashimiTheme.accent : .clear, lineWidth: 4)
            )
            .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 15)
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(.card)
        .focused($isFocused)
    }
}

// MARK: - App Info Item

struct AppInfoItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 16))
                .foregroundStyle(SashimiTheme.textTertiary)
            Text(value)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(SashimiTheme.textSecondary)
        }
    }
}

// MARK: - Sign Out Button

struct SignOutButton: View {
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 20))
                Text("Sign Out")
                    .font(.system(size: 22, weight: .medium))
            }
            .foregroundStyle(isFocused ? .white : .red.opacity(0.8))
            .padding(.horizontal, 40)
            .padding(.vertical, 16)
            .background(
                Capsule()
                    .fill(isFocused ? Color.red : Color.red.opacity(0.15))
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
    }
}

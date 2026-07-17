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
                // Rebuild the entire tab hierarchy when the active server
                // changes — every view model reloads against the new server.
                MainTabView()
                    .id(sessionManager.activeServerId)
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
    // Which nav item currently holds focus; nil means focus is in content
    // (so the rail rests collapsed). Drives the pullout expansion.
    @FocusState private var focusedNav: Int?
    @State private var showServerSwitcher = false
    @State private var showAddServer = false

    private let railWidth: CGFloat = 100
    private let panelWidth: CGFloat = 360

    private var expanded: Bool { focusedNav != nil }

    private static let navItems: [(index: Int, title: String, icon: String)] = [
        (0, "Home", "house"),
        (1, "Library", "square.grid.2x2"),
        (2, "Search", "magnifyingglass"),
        (3, "Settings", "gearshape")
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Content sits to the right of the slim rail and never moves —
            // the expanded panel overlays it (blurred), Plex-style.
            content
                .padding(.leading, railWidth)
                .blur(radius: expanded ? 8 : 0)
                .animation(.easeInOut(duration: 0.28), value: expanded)

            // Dim scrim over content while the panel is open
            Color.black
                .opacity(expanded ? 0.45 : 0)
                .allowsHitTesting(false)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.28), value: expanded)

            sidebar
        }
        .ignoresSafeArea()
        .onExitCommand(perform: exitCommandAction)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case 1: LibraryView(onBackAtRoot: { selectedTab = 0 })
        case 2: SearchView(onBackAtRoot: { selectedTab = 0 })
        case 3: SettingsView(onBackAtRoot: { selectedTab = 0 })
        default: HomeView()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 36) {
            // Logo (mark only when collapsed, mark + wordmark when expanded)
            HStack(spacing: 16) {
                Image(systemName: "fish.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(SashimiTheme.accent)
                    .frame(width: 44)
                if expanded {
                    Image("Logo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 60)
                        .fixedSize()
                }
            }
            .padding(.bottom, 12)

            ForEach(Self.navItems, id: \.index) { item in
                navButton(item.index, item.title, item.icon)
            }

            Spacer()

            avatarButton
        }
        .padding(.vertical, 70)
        .padding(.horizontal, 28)
        .frame(width: expanded ? panelWidth : railWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .opacity(expanded ? 1 : 0.9)
                .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 0.28), value: expanded)
        .focusSection()
    }

    private func navButton(_ index: Int, _ title: String, _ icon: String) -> some View {
        Button {
            selectedTab = index
        } label: {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 44)
                if expanded {
                    Text(title)
                        .font(.system(size: 26, weight: .semibold))
                        .fixedSize()
                }
            }
            .foregroundStyle(navTint(index))
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .focused($focusedNav, equals: index)
    }

    private func navTint(_ index: Int) -> Color {
        if focusedNav == index { return .white }
        if selectedTab == index { return SashimiTheme.accent }
        return .white.opacity(0.55)
    }

    private var avatarButton: some View {
        Button {
            showServerSwitcher = true
        } label: {
            HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [SashimiTheme.accent, SashimiTheme.accent.opacity(0.6)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                    if let userId = sessionManager.currentUser?.id,
                       let imageURL = JellyfinClient.shared.userImageURL(userId: userId) {
                        AsyncImage(url: imageURL) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: "person.fill").foregroundStyle(.white)
                        }
                        .frame(width: 52, height: 52)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.fill").foregroundStyle(.white)
                    }
                }
                .frame(width: 44)
                if expanded {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sessionManager.currentUser?.name ?? "Account")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Switch server")
                            .font(.system(size: 17))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .fixedSize()
                }
            }
        }
        .buttonStyle(.plain)
        .focused($focusedNav, equals: 99)
        .confirmationDialog("Switch Server", isPresented: $showServerSwitcher, titleVisibility: .visible) {
            ForEach(sessionManager.servers) { server in
                Button(server.id == sessionManager.activeServerId ? "✓ \(server.name)" : server.name) {
                    Task { await sessionManager.switchServer(to: server.id) }
                }
            }
            Button("Add Server…") { showAddServer = true }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showAddServer) {
            AddServerSheet()
        }
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

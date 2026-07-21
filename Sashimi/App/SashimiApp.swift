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

/// Nav-item style with no default tvOS focus platter — focus is shown by the
/// soft highlight we draw ourselves. Only a subtle press-scale remains.
private struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct MainTabView: View {
    @EnvironmentObject private var sessionManager: SessionManager

    /// A destination in the rail. Libraries are dynamic, so this is an enum
    /// rather than a tab index.
    enum NavID: Hashable {
        case home, search, settings, avatar
        case library(String)
    }

    // Which nav item currently holds focus; nil means focus is in content
    // (so the rail rests collapsed). Drives the pullout expansion.
    @FocusState private var focusedNav: NavID?
    @Namespace private var mainScope
    @State private var selection: NavID = .home
    @State private var libraries: [JellyfinLibrary] = []
    @State private var showServerSwitcher = false
    @State private var showAddServer = false
    // One-shot: the hero grabs focus once on cold launch (the rail otherwise
    // steals it while content is still loading). Also gates the edge guard so
    // it doesn't interfere with that initial focus resolution.
    @State private var didInitialHomeFocus = false

    private let railWidth: CGFloat = 120
    private let panelWidth: CGFloat = 340

    private var expanded: Bool { focusedNav != nil }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Content sits to the right of the slim rail and never moves —
            // the expanded panel overlays it. Kept bright/unblurred so the
            // previewed section reads clearly as you roam the rail.
            content
                .padding(.leading, railWidth)
                // Content wins initial focus so the app opens with the rail
                // resting (collapsed), not auto-expanded onto Home.
                .prefersDefaultFocus(true, in: mainScope)

            // Invisible focus buffer at the rail/content seam. From content,
            // one left press lands here (nothing visible happens); a second
            // left press crosses into the rail — so the nav takes a deliberate
            // double-press, not a single accidental swipe. Inert until the
            // initial Home focus resolves, and only live while focus is in
            // content, so exiting the rail stays a single right press.
            Color.clear
                .frame(width: 6)
                .frame(maxHeight: .infinity)
                .focusable(didInitialHomeFocus && focusedNav == nil)
                .focusEffectDisabled()
                .padding(.leading, railWidth)

            sidebar
        }
        .ignoresSafeArea()
        .focusScope(mainScope)
        .onExitCommand(perform: exitCommandAction)
        .task { await loadLibraries() }
        // Focus-driven: moving focus onto a nav item switches the content
        // behind the blur immediately — no click needed (Plex behavior).
        .onChange(of: focusedNav) { _, newValue in
            if let newValue, newValue != .avatar {
                selection = newValue
            }
        }
    }

    private func loadLibraries() async {
        if let libs = try? await JellyfinClient.shared.getLibraryViews() {
            libraries = libs
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .home, .avatar:
            HomeView(focusNamespace: mainScope, onHeroReady: handleHeroReady)
        case .search:
            SearchView(onBackAtRoot: { selection = .home })
        case .settings:
            SettingsView(onBackAtRoot: { selection = .home })
        case .library(let id):
            if let lib = libraries.first(where: { $0.id == id }) {
                LibraryDetailView(library: LibraryView_Model(from: lib))
                    .id(id)  // rebuild the grid when switching libraries
            } else {
                HomeView(focusNamespace: mainScope, onHeroReady: handleHeroReady)
            }
        }
    }

    /// Cold-launch focus fix: the rail grabs focus while the hero is still
    /// loading, so once the hero has content, drop rail focus and let the
    /// hero (the mainScope default-focus target) take it. Runs once; the edge
    /// guard is armed a beat later so it can't interfere with this handoff.
    private func handleHeroReady() {
        guard !didInitialHomeFocus, selection == .home || selection == .avatar else { return }
        focusedNav = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            didInitialHomeFocus = true
        }
    }

    private struct NavRow: Identifiable {
        let id: NavID
        let title: String
        let icon: String
    }

    /// Nav rows in order: Home, each library, Search, Settings.
    private var navRows: [NavRow] {
        var rows: [NavRow] = [NavRow(id: .home, title: "Home", icon: "house")]
        for lib in libraries {
            rows.append(NavRow(id: .library(lib.id), title: lib.name, icon: libraryIcon(lib)))
        }
        rows.append(NavRow(id: .search, title: "Search", icon: "magnifyingglass"))
        rows.append(NavRow(id: .settings, title: "Settings", icon: "gearshape"))
        return rows
    }

    private func libraryIcon(_ lib: JellyfinLibrary) -> String {
        if lib.name.lowercased().contains("youtube") { return "play.rectangle.fill" }
        switch lib.collectionType {
        case "movies": return "film.stack"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "musicvideos": return "music.note.tv"
        case "books": return "books.vertical"
        case "photos", "homevideos": return "photo.stack"
        case "playlists": return "list.and.film"
        case "boxsets": return "square.stack.3d.up.fill"
        case "livetv": return "dot.radiowaves.left.and.right"
        default: return "rectangle.stack"
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 30) {
            // Sushi mark is always visible; the "Sashimi" wordmark unfolds
            // beside it only when the rail is pulled out.
            HStack(spacing: 14) {
                Image("SidebarLogoMark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: expanded ? 60 : 46, height: expanded ? 60 : 46)
                if expanded {
                    Text("Sashimi")
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .frame(height: 60)

            // Balanced spacers put the logo at the top, avatar at the foot,
            // and the nav group vertically centered between them.
            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 26) {
                ForEach(navRows, id: \.id) { row in
                    navButton(row.id, row.title, row.icon)
                }
            }

            Spacer(minLength: 16)

            avatarButton

            // App version under the avatar (centered when collapsed)
            Text(appVersion)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
                .padding(.top, 4)
        }
        .padding(.vertical, 50)
        .padding(.leading, expanded ? 36 : 38)
        .padding(.trailing, expanded ? 28 : 38)
        .frame(width: expanded ? panelWidth : railWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        // Dim the rail's contents when resting (not engaged); full on focus.
        // Applied before .background so only the foreground fades, not the rail.
        .opacity(expanded ? 1.0 : 0.68)
        .background {
            // Match the Home screen's vertical gradient so the rail reads as
            // part of the same surface, then fade the right edge into content.
            LinearGradient(
                colors: [SashimiTheme.background, Color.black],
                startPoint: .top, endPoint: .bottom
            )
            .overlay(
                LinearGradient(
                    colors: [Color.black.opacity(expanded ? 0.35 : 0.0), Color.clear],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .ignoresSafeArea()
        }
        // Hairline right edge so the rail reads as a defined strip (makes the
        // icon centering legible even when the content behind is dark).
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 0.28), value: expanded)
        .focusSection()
    }

    private func navButton(_ id: NavID, _ title: String, _ icon: String) -> some View {
        Button {
            selection = id
        } label: {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 44)
                if expanded {
                    Text(title)
                        .font(.system(size: 25, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(navTint(id))
            .padding(.vertical, 11)
            .padding(.horizontal, expanded ? 16 : 0)
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .background(focusHighlight(focusedNav == id))
        }
        .buttonStyle(SidebarButtonStyle())
        .focused($focusedNav, equals: id)
    }

    /// Soft accent highlight in place of the tvOS default white focus platter.
    private func focusHighlight(_ isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(isFocused ? 0.14 : 0))
    }

    /// Jellyfin purple, sampled from the logo — the selected-item highlight.
    private static let jellyfinPurple = Color(red: 189 / 255, green: 62 / 255, blue: 237 / 255)

    private var appVersion: String {
        "v" + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
    }

    private func navTint(_ id: NavID) -> Color {
        if focusedNav == id { return .white }
        if selection == id { return Self.jellyfinPurple }
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
            .padding(.vertical, 10)
            .padding(.horizontal, expanded ? 12 : 0)
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .background(focusHighlight(focusedNav == .avatar))
        }
        .buttonStyle(SidebarButtonStyle())
        .focused($focusedNav, equals: .avatar)
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

    /// Menu/back button handling. Returns nil on Home so the press propagates
    /// to the system (suspends the app). The previous exit(0) flow is Apple-
    /// prohibited — see issue #174.
    private var exitCommandAction: (() -> Void)? {
        if selection != .home {
            return { selection = .home }
        }
        return nil
    }
}

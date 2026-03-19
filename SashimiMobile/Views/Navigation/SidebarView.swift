import SwiftUI
import NukeUI

enum SidebarSelection: Hashable {
    case home
    case search
    case downloads
    case settings
    case library(id: String, name: String, collectionType: String?)

    var displayName: String {
        switch self {
        case .home: return "Home"
        case .search: return "Search"
        case .downloads: return "Downloads"
        case .settings: return "Settings"
        case .library(_, let name, _): return name
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .search: return "magnifyingglass"
        case .downloads: return "arrow.down.circle"
        case .settings: return "gearshape"
        case .library(_, _, let collectionType):
            switch collectionType {
            case "movies": return "film"
            case "tvshows": return "tv"
            case "music": return "music.note"
            default: return "folder"
            }
        }
    }
}

struct MainNavigationView: View {
    @State private var selection: SidebarSelection = .home
    @State private var sidebarVisible = false
    @State private var libraries: [JellyfinLibrary] = []
    @ObservedObject private var sessionManager = SessionManager.shared
    @ObservedObject private var downloadManager = DownloadManager.shared

    private let sidebarWidth: CGFloat = 280

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Main content with custom header
                VStack(spacing: 0) {
                    // Custom header bar
                    headerBar

                    // Content area
                    NavigationStack {
                        detailView
                            .navigationBarHidden(true)
                    }
                    .id(selection)
                }
                .frame(width: geometry.size.width)
                .offset(x: sidebarVisible ? sidebarWidth : 0)

                // Dimming overlay when sidebar is open
                if sidebarVisible {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .offset(x: sidebarWidth)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                sidebarVisible = false
                            }
                        }
                }

                // Sidebar
                sidebarContent
                    .frame(width: sidebarWidth)
                    .offset(x: sidebarVisible ? 0 : -sidebarWidth)
            }
        }
        .task {
            await loadLibraries()
        }
        .overlay(alignment: .top) {
            if let message = downloadManager.toastMessage {
                Button {
                    selection = .downloads
                    downloadManager.toastMessage = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(message)
                            .font(MobileTypography.body)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation {
                            downloadManager.toastMessage = nil
                        }
                    }
                }
            }
        }
        .animation(.easeInOut, value: downloadManager.toastMessage)
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Logo at very top
            HStack {
                Image("SidebarLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text("Sashimi")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(MobileColors.textPrimary)
            }
            .padding(.horizontal, MobileSpacing.md)
            .padding(.top, MobileSpacing.md)
            .padding(.bottom, MobileSpacing.md)

            // Home
            sidebarRow(item: .home)

            // Divider
            Rectangle()
                .fill(MobileColors.textTertiary.opacity(0.3))
                .frame(height: 1)
                .padding(.horizontal, MobileSpacing.md)
                .padding(.vertical, MobileSpacing.xs)

            // Libraries
            ForEach(libraries) { library in
                sidebarRow(item: .library(
                    id: library.id,
                    name: library.name,
                    collectionType: library.collectionType
                ))
            }

            // Divider
            Rectangle()
                .fill(MobileColors.textTertiary.opacity(0.3))
                .frame(height: 1)
                .padding(.horizontal, MobileSpacing.md)
                .padding(.vertical, MobileSpacing.xs)

            // Search
            sidebarRow(item: .search)

            // Downloads
            sidebarRow(item: .downloads)

            Spacer()

            // Settings at bottom
            Rectangle()
                .fill(MobileColors.textTertiary.opacity(0.3))
                .frame(height: 1)
                .padding(.horizontal, MobileSpacing.md)

            sidebarRow(item: .settings)
                .padding(.bottom, MobileSpacing.md)
        }
        .frame(maxHeight: .infinity)
        .background(MobileColors.cardBackground.ignoresSafeArea())
    }

    private func sidebarRow(item: SidebarSelection) -> some View {
        Button {
            selection = item
            withAnimation(.easeInOut(duration: 0.25)) {
                sidebarVisible = false
            }
        } label: {
            HStack(spacing: MobileSpacing.md) {
                Image(systemName: item.icon)
                    .font(.system(size: 20))
                    .frame(width: 24)
                Text(item.displayName)
                    .font(MobileTypography.body)
                Spacer()
            }
            .foregroundStyle(selection == item ? MobileColors.accent : MobileColors.textPrimary)
            .padding(.horizontal, MobileSpacing.md)
            .padding(.vertical, MobileSpacing.sm)
            .background(selection == item ? MobileColors.accent.opacity(0.15) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var headerBar: some View {
        HStack(alignment: .center) {
            // Hamburger menu
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 24))
                .foregroundColor(MobileColors.textPrimary)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        sidebarVisible.toggle()
                    }
                }

            Spacer()

            userAvatarView
        }
        .padding(.horizontal, MobileSpacing.md)
        .padding(.vertical, MobileSpacing.sm)
        .background(MobileColors.background)
    }

    @ViewBuilder
    private var userAvatarView: some View {
        if let user = sessionManager.currentUser,
           let avatarURL = userAvatarURL(for: user) {
            LazyImage(url: avatarURL) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if state.error != nil {
                    defaultAvatarView(for: user)
                } else {
                    defaultAvatarView(for: user)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
        } else if let user = sessionManager.currentUser {
            defaultAvatarView(for: user)
        } else {
            Image(systemName: "person.circle")
                .font(.title2)
                .foregroundStyle(MobileColors.textSecondary)
        }
    }

    private func defaultAvatarView(for user: UserDto) -> some View {
        Circle()
            .fill(MobileColors.accent)
            .frame(width: 40, height: 40)
            .overlay {
                Text(String(user.name.prefix(1)).uppercased())
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    private func userAvatarURL(for user: UserDto) -> URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else {
            return nil
        }
        return URL(string: "\(serverURL)/Users/\(user.id)/Images/Primary?maxWidth=64")
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .home:
            MobileHomeView()
        case .search:
            MobileSearchView()
        case .downloads:
            DownloadsListView()
        case .settings:
            MobileSettingsView()
        case .library(let id, let name, let collectionType):
            MobileLibraryBrowseView(
                libraryId: id,
                libraryName: name,
                collectionType: collectionType
            )
        }
    }

    private func loadLibraries() async {
        do {
            libraries = try await JellyfinClient.shared.getLibraryViews()
        } catch {
            // Silently fail
        }
    }
}

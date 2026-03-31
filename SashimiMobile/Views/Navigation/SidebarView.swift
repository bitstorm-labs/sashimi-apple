import SwiftUI
import SwiftData
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
    @State private var sidebarWidth: CGFloat = 200
    @State private var navigationResetId: Int = 0
    @ObservedObject private var serverManager = ServerManager.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

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
                            .navigationBarHidden(selection == .search ? false : true)
                    }
                    .id("\(selection)-\(navigationResetId)")
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
                    .fixedSize(horizontal: true, vertical: false)
                    .background(GeometryReader { sidebarGeo in
                        Color.clear.onAppear {
                            sidebarWidth = sidebarGeo.size.width
                        }
                        .onChange(of: sidebarGeo.size.width) { _, newWidth in
                            sidebarWidth = newWidth
                        }
                    })
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
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: MobileCornerRadius.xl,
                topTrailingRadius: MobileCornerRadius.xl
            )
        )
    }

    private func sidebarRow(item: SidebarSelection) -> some View {
        Button {
            if selection == item {
                navigationResetId += 1
            } else {
                selection = item
            }
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
            }
            .foregroundStyle(selection == item ? MobileColors.accent : MobileColors.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
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

            // Download activity indicator
            if selection != .downloads {
                downloadIndicator
            }

            userAvatarView
        }
        .padding(.horizontal, MobileSpacing.md)
        .padding(.vertical, MobileSpacing.sm)
        .background(MobileColors.background)
    }

    @ViewBuilder
    private var userAvatarView: some View {
        if let avatarURL = serverManager.primaryServer?.userImageURL(maxWidth: 64) {
            LazyImage(url: avatarURL) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if state.error != nil {
                    defaultAvatarNameView
                } else {
                    defaultAvatarNameView
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
        } else if serverManager.currentUserName != nil {
            defaultAvatarNameView
        } else {
            Image(systemName: "person.circle")
                .font(.title2)
                .foregroundStyle(MobileColors.textSecondary)
        }
    }

    private var defaultAvatarNameView: some View {
        Circle()
            .fill(MobileColors.accent)
            .frame(width: 40, height: 40)
            .overlay {
                Text(String((serverManager.currentUserName ?? "U").prefix(1)).uppercased())
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    @ViewBuilder
    private var detailView: some View {
        if !networkMonitor.isConnected && selection != .downloads && selection != .settings {
            OfflineHomeView()
        } else {
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
    }

    @ViewBuilder
    private var downloadIndicator: some View {
        // Use in-memory state for active (always current), SwiftData for completed/failed
        let activeCount = downloadManager.activeDownloads.count
            + downloadManager.preparingItems.count
            + downloadManager.queuedCount
        let failedCount = downloadFailedCount()
        let completedCount = downloadCompletedCount()
        let speed = downloadManager.downloadSpeed

        HStack(spacing: 6) {
            if activeCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(MobileColors.accent)
                        .symbolEffect(.pulse)
                    Text("\(activeCount)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MobileColors.accent)
                    if !speed.isEmpty {
                        Text("(\(speed))")
                            .font(.system(size: 11))
                            .foregroundStyle(MobileColors.accent.opacity(0.8))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(MobileColors.accent.opacity(0.15))
                .clipShape(Capsule())
            }

            if completedCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(MobileColors.success)
                    Text("\(completedCount)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MobileColors.success)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(MobileColors.success.opacity(0.15))
                .clipShape(Capsule())
            }

            if failedCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(MobileColors.error)
                        .symbolEffect(.pulse)
                    Text("\(failedCount)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MobileColors.error)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(MobileColors.error.opacity(0.15))
                .clipShape(Capsule())
            }
        }
        .onTapGesture { selection = .downloads }
    }

    private func downloadCompletedCount() -> Int {
        _ = downloadManager.stateVersion
        guard let container = DownloadManager.shared.modelContainer else { return 0 }
        let context = ModelContext(container)
        let predicate = #Predicate<DownloadedItem> { $0.statusRaw == "completed" }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    private func downloadFailedCount() -> Int {
        _ = downloadManager.stateVersion
        guard let container = DownloadManager.shared.modelContainer else { return 0 }
        let context = ModelContext(container)
        let predicate = #Predicate<DownloadedItem> { $0.statusRaw == "failed" }
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: predicate)
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    private func loadLibraries() async {
        do {
            libraries = try await JellyfinClient.shared.getLibraryViews()
        } catch {
            // Silently fail
        }
    }
}

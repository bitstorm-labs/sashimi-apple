import SwiftUI

/// Home while the server can't be used: the downloads, laid out like the
/// online Home (the iPad's hero and rows, the iPhone's header and rows) with
/// the same cards, so going offline changes what is listed, not the app.
struct OfflineHomeView: View {
    @StateObject private var library = OfflineLibrary()
    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @State private var playingItem: BaseItemDto?
    @State private var playingServerID: String?
    @State private var openedShow: OfflineShowRoute?
    @State private var heroIndex = 0
    /// The fixed hero wallpaper dims to black as the rows scroll up over it.
    @State private var heroScrollFade: Double = 0
    @GestureState private var isTouchingHero = false

    private var isPad: Bool {
        MobileLayoutIdiom.usesPadLayout
    }

    private var continueWatchingWidth: CGFloat {
        isPad ? 280 : PhoneSizing.continueWatchingWidth
    }

    private var posterWidth: CGFloat {
        isPad ? MobileSizing.posterWidth : PhoneSizing.posterWidth
    }

    var body: some View {
        Group {
            if isPad {
                padLayout
            } else {
                phoneLayout
            }
        }
        .navigationDestination(item: $openedShow) { route in
            OfflineShowView(showKey: route.key)
        }
        .fullScreenPlayer(item: $playingItem, serverID: playingServerID)
        .onAppear { library.reload() }
        .onChange(of: downloadManager.stateVersion) { _, _ in
            library.reload()
        }
    }

    // MARK: - iPad (MobileHomeView's layout)

    private var padLayout: some View {
        GeometryReader { proxy in
            let hero = PadHeroMetrics(proxy: proxy)
            let slides = library.heroEntries.map { HeroSlide.library($0.item) }

            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [MobileColors.background, Color.black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                if !slides.isEmpty {
                    HeroSection(
                        slides: slides,
                        libraryNames: [:],
                        currentIndex: $heroIndex,
                        layout: hero.layout,
                        isPaused: isTouchingHero,
                        localBackdrop: heroBackdrop
                    )
                    .overlay(Color.black.opacity(heroScrollFade))
                    .frame(maxWidth: .infinity, alignment: .top)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { openHeroSlide() }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: MobileSpacing.xl) {
                        if !slides.isEmpty {
                            heroRevealSpacer(height: hero.revealHeight)
                        }
                        rows
                    }
                    .padding(.top, slides.isEmpty ? MobileSpacing.md : 0)
                    .padding(.bottom, MobileSpacing.md)
                }
                .refreshable { refresh() }
            }
        }
    }

    private func heroBackdrop(for item: BaseItemDto) -> Image? {
        library.heroEntries.first { $0.itemId == item.id }.flatMap(OfflineArtwork.landscape(for:))
    }

    /// The online Home's reveal spacer: a clear band over the fixed hero that
    /// is also its touch surface (tap opens, swipe changes slide).
    private func heroRevealSpacer(height: CGFloat) -> some View {
        Color.clear
            .frame(height: height)
            .contentShape(Rectangle())
            .onTapGesture { openHeroSlide() }
            .simultaneousGesture(heroSwipe)
            .onGeometryChange(for: Bool.self) { geometry in
                geometry.frame(in: .scrollView).minY < -8
            } action: { scrolled in
                withAnimation(.easeOut(duration: 0.3)) {
                    heroScrollFade = scrolled ? 1 : 0
                }
            }
            .accessibilityHidden(true)
    }

    private var heroSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($isTouchingHero) { _, touching, _ in
                touching = true
            }
            .onEnded { value in
                let horizontal = value.translation.width
                guard abs(horizontal) > 50,
                      abs(horizontal) > abs(value.translation.height) * 1.5 else { return }
                let count = library.heroEntries.count
                guard count > 1 else { return }
                let step = horizontal < 0 ? 1 : -1
                withAnimation(.easeInOut(duration: 0.6)) {
                    heroIndex = ((min(heroIndex, count - 1) + step) % count + count) % count
                }
            }
    }

    private func openHeroSlide() {
        let entries = library.heroEntries
        guard !entries.isEmpty else { return }
        open(entries[min(heroIndex, entries.count - 1)])
    }

    // MARK: - iPhone (PhoneHomeView's layout)

    private var phoneLayout: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileSpacing.lg) {
                rows
            }
            .padding(.vertical, MobileSpacing.sm)
        }
        .background(MobileColors.background)
        .navigationBarHidden(true)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                Image("SidebarLogo")
                    .resizable().scaledToFit()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                Text("Sashimi")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(MobileColors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, MobileSpacing.md)
            .padding(.vertical, MobileSpacing.xs)
            .background(MobileColors.background)
        }
        .refreshable { refresh() }
    }

    // MARK: - Rows

    @ViewBuilder
    private var rows: some View {
        OfflineStatusBanner()
            .padding(.horizontal, MobileSpacing.md)

        if library.entries.isEmpty {
            ContentUnavailableView(
                "No Downloads",
                systemImage: "arrow.down.circle",
                description: Text("Download movies and episodes while online to watch them here.")
            )
            .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            landscapeRow("Continue Watching", entries: library.continueWatching)
            landscapeRow("Next Up", entries: library.nextUp)
            moviesRow
            showsRow
        }
    }

    /// Continue Watching and Next Up use the online Continue Watching card.
    @ViewBuilder
    private func landscapeRow(_ title: String, entries: [OfflineEntry]) -> some View {
        if !entries.isEmpty {
            row(title) {
                LazyHStack(spacing: MobileSpacing.md) {
                    ForEach(entries) { entry in
                        Button {
                            open(entry)
                        } label: {
                            MobileContinueWatchingCard(
                                item: entry.item,
                                width: continueWatchingWidth,
                                artwork: OfflineArtwork.landscape(for: entry)
                            )
                            .pendingSyncBadge(entry.needsSync)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var moviesRow: some View {
        let movies = library.movies
        if !movies.isEmpty {
            row("Movies") {
                LazyHStack(spacing: MobileSpacing.sm) {
                    ForEach(movies) { entry in
                        Button {
                            play(entry)
                        } label: {
                            MobileRecentlyAddedCard(
                                item: entry.item,
                                width: posterWidth,
                                libraryName: nil,
                                isCircular: false,
                                isLandscape: false,
                                badgeCount: nil,
                                artwork: OfflineArtwork.poster(for: entry)
                            )
                            .pendingSyncBadge(entry.needsSync)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var showsRow: some View {
        let shows = library.shows
        if !shows.isEmpty {
            row("TV Shows") {
                LazyHStack(spacing: MobileSpacing.sm) {
                    ForEach(shows) { show in
                        Button {
                            openedShow = OfflineShowRoute(key: show.id)
                        } label: {
                            MobileRecentlyAddedCard(
                                item: show.seriesItem,
                                width: posterWidth,
                                libraryName: nil,
                                isCircular: false,
                                isLandscape: false,
                                // The online card's "N new": unwatched episodes
                                // that are here to watch.
                                badgeCount: show.unplayedCount > 0 ? show.unplayedCount : nil,
                                artwork: show.artworkEntry.flatMap(OfflineArtwork.poster(for:))
                            )
                            .pendingSyncBadge(show.needsSync)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// The online rows' frame: headline title over a horizontal strip.
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text(title)
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)
                .padding(.horizontal, MobileSpacing.md)

            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .padding(.horizontal, MobileSpacing.md)
            }
        }
    }

    // MARK: - Actions

    /// An episode opens its show (the offline stand-in for the detail page);
    /// a movie, which has no offline page, plays.
    private func open(_ entry: OfflineEntry) {
        if entry.itemType == .episode {
            openedShow = OfflineShowRoute(key: entry.seriesKey)
        } else {
            play(entry)
        }
    }

    private func play(_ entry: OfflineEntry) {
        ThemeSongPlayer.shared.stopForPlayback()
        playingServerID = entry.serverID
        playingItem = entry.item
    }

    private func refresh() {
        networkMonitor.requestProbe()
        library.reload()
    }
}

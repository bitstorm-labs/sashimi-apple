import SwiftUI

struct MobileHomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var rowSettings = HomeRowSettings.shared
    @StateObject private var channelsViewModel = ChannelsViewModel()
    @State private var tunedChannel: TunedChannel?
    @State private var heroIndex = 0
    /// The fixed hero wallpaper dims to black as the rows scroll up over it.
    @State private var heroScrollFade: Double = 0
    /// Opened by tapping the hero.
    @State private var heroDestination: BaseItemDto?
    /// A finger is on the hero: hold the rotation. GestureState so a drag the
    /// scroll view takes over (and so never "ends") still resets it.
    @GestureState private var isTouchingHero = false

    /// The same rotation the Apple TV hero shows (`HeroRotation.slides`).
    private var heroSlides: [HeroSlide] {
        HeroRotation.slides(libraryItems: viewModel.heroItems, channels: channelsViewModel.cards)
    }

    var body: some View {
        GeometryReader { proxy in
            let hero = PadHeroMetrics(proxy: proxy)
            let slides = heroSlides

            ZStack(alignment: .topLeading) {
                // The tvOS Home page: theme background fading to black.
                LinearGradient(
                    colors: [MobileColors.background, Color.black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                // Fixed hero wallpaper pinned to the top, BEHIND the scrolling
                // rows, as on tvOS (HomeView). It starts below the status bar,
                // like the rest of the iPad UI.
                if !slides.isEmpty {
                    heroBackdrop(slides: slides, metrics: hero)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: MobileSpacing.xl) {
                        if !slides.isEmpty {
                            heroRevealSpacer(metrics: hero)
                        }

                        LazyVStack(alignment: .leading, spacing: MobileSpacing.xl) {
                            if viewModel.isLoading && viewModel.continueWatchingItems.isEmpty {
                                loadingView
                            } else {
                                contentView
                            }
                        }
                    }
                    .padding(.top, slides.isEmpty ? MobileSpacing.md : 0)
                    .padding(.bottom, MobileSpacing.md)
                }
                .refreshable {
                    await viewModel.loadContent()
                }
            }
        }
        .navigationDestination(item: $heroDestination) { item in
            AdaptiveDetailView(item: item, libraryName: viewModel.heroItemLibraryNames[item.id])
        }
        .task {
            rowSettings.use(serverID: SessionManager.shared.activeServerId)
            await viewModel.loadContent()
            // After the main content: a server without the Channels plugin
            // answers 404 and yields an empty row, so this must never gate the
            // rest of Home on it.
            await channelsViewModel.load()
            await keepChannelsCurrent()
        }
        .fullScreenCover(item: $tunedChannel) { tuned in
            MobilePlayerView(item: tuned.item, channelContext: tuned.context)
        }
        .onChange(of: tunedChannel) { oldValue, newValue in
            // Coming back from a channel: the schedule moved on while it
            // played, so the cards are stale by definition.
            if oldValue != nil && newValue == nil {
                Task { await channelsViewModel.load() }
            }
        }
        .onAppear {
            // Refresh when navigating back to home (e.g. after watching something)
            if !viewModel.continueWatchingItems.isEmpty || !viewModel.libraries.isEmpty {
                Task { await viewModel.loadContent() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sashimiChannelsDidChange)) { _ in
            Task { await channelsViewModel.load() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from the background: something may have been watched on
            // another device. Reload if what Home shows has gone stale.
            guard phase == .active else { return }
            Task { await viewModel.refreshIfStale() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackDidStop)) { _ in
            Task {
                try? await Task.sleep(for: .seconds(0.5))
                await viewModel.loadContent()
            }
        }
        .onChange(of: viewModel.libraries) { _, libraries in
            rowSettings.updateLibraries(libraries)
        }
    }

    // MARK: - Hero

    private func heroBackdrop(slides: [HeroSlide], metrics: PadHeroMetrics) -> some View {
        HeroSection(
            slides: slides,
            libraryNames: viewModel.heroItemLibraryNames,
            currentIndex: $heroIndex,
            layout: metrics.layout,
            serverID: SessionManager.shared.activeServerId,
            isPaused: isTouchingHero
        )
        .overlay(Color.black.opacity(heroScrollFade))
        .frame(maxWidth: .infinity, alignment: .top)
        // The touch surface is the reveal spacer in front of the hero; VoiceOver
        // reaches the hero itself, so the same actions live here.
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openCurrentHeroSlide() }
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: showHeroSlide(offset: 1)
            case .decrement: showHeroSlide(offset: -1)
            @unknown default: break
            }
        }
    }

    /// Clear spacer revealing the fixed hero above the first row (a touch less
    /// than the hero, so the first row overlaps its faded bottom edge, as on
    /// tvOS). It sits in front of the hero, so it is also the hero's touch
    /// surface: tap opens the slide, a horizontal swipe changes it.
    private func heroRevealSpacer(metrics: PadHeroMetrics) -> some View {
        Color.clear
            .frame(height: metrics.revealHeight)
            .contentShape(Rectangle())
            .onTapGesture { openCurrentHeroSlide() }
            .simultaneousGesture(heroSwipe)
            // As on tvOS: at the top the hero is lit; once the rows move up
            // over it, it eases to black. Not a fade that tracks the finger:
            // half-dimmed, the hero's title shows through the row headers
            // sliding over it.
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
                // Horizontal and deliberate; anything else was a scroll.
                guard abs(horizontal) > 50,
                      abs(horizontal) > abs(value.translation.height) * 1.5 else { return }
                showHeroSlide(offset: horizontal < 0 ? 1 : -1)
            }
    }

    private func showHeroSlide(offset: Int) {
        let count = heroSlides.count
        guard count > 1 else { return }
        let current = min(heroIndex, count - 1)
        withAnimation(.easeInOut(duration: 0.6)) {
            heroIndex = ((current + offset) % count + count) % count
        }
    }

    /// A library slide opens its detail, as a card does. A channel slide tunes
    /// in, as its SashimiTV card does: it is what is on air, not a title page.
    private func openCurrentHeroSlide() {
        let slides = heroSlides
        guard !slides.isEmpty else { return }
        let slide = slides[min(heroIndex, slides.count - 1)]
        if let stamp = slide.channel,
           let card = channelsViewModel.cards.first(where: { $0.channel.id == stamp.id }) {
            tuneToChannel(card)
        } else {
            heroDestination = slide.item
        }
    }

    private var loadingView: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 300)
    }

    @ViewBuilder
    private var contentView: some View {
        ForEach(rowSettings.rows.filter { $0.isEnabled }) { row in
            rowView(for: row)
        }

        // Empty state
        if viewModel.continueWatchingItems.isEmpty && viewModel.libraries.isEmpty {
            emptyStateView
        }
    }

    @ViewBuilder
    private func rowView(for row: HomeRowConfig) -> some View {
        switch row.type {
        case .builtIn(.continueWatching):
            if !viewModel.continueWatchingItems.isEmpty {
                let libNames = viewModel.continueWatchingLibraryNames
                MobileContinueWatchingRow(
                    items: viewModel.continueWatchingItems,
                    libraryNames: libNames
                ) { item in
                    AdaptiveDetailView(item: item, libraryName: libNames[item.id])
                }
            }

        case .builtIn(.channels):
            if !channelsViewModel.cards.isEmpty {
                MobileChannelsRow(cards: channelsViewModel.cards, cardWidth: MobileSizing.channelCardWidth) { card in
                    tuneToChannel(card)
                }
            }

        case .library(let libraryId, let libraryName):
            let library = viewModel.libraries.first(where: { $0.id == libraryId })
            MobileRecentlyAddedRow(
                libraryId: libraryId,
                libraryName: libraryName,
                collectionType: library?.collectionType
            ) { item in
                AdaptiveDetailView(item: item, libraryName: libraryName)
            }
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            "No Content",
            systemImage: "tv",
            description: Text("Start watching something to see it here.")
        )
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    /// Resolve what the channel is airing and open the player on it.
    ///
    /// Resolved at the moment of tapping rather than from the card: the row may
    /// have been on screen for a while, and a channel moves on whether or not
    /// anyone is looking at it.
    private func tuneToChannel(_ card: ChannelCard) {
        Task {
            guard let tuned = await channelsViewModel.tuneIn(to: card.channel) else {
                // Went off air between rendering and tapping. Refresh so the row
                // tells the truth rather than appearing to do nothing.
                await channelsViewModel.load()
                return
            }
            guard let item = try? await JellyfinClient.shared.getItem(itemId: tuned.itemID) else { return }
            tunedChannel = TunedChannel(item: item, context: tuned.context)
        }
    }

    /// Keep the FinTV row honest while Home is on screen.
    ///
    /// Wake when the soonest programme actually ends rather than on a fixed
    /// tick — a poll shows a finished programme for up to its whole interval,
    /// and that is exactly the moment someone is looking at it. Five minutes is
    /// only a ceiling, for when nothing ends soon and because the schedule can
    /// be rebuilt underneath us when the library changes.
    private func keepChannelsCurrent() async {
        let ceiling: Double = 300

        while !Task.isCancelled {
            let soonest = channelsViewModel.cards.compactMap(\.endsAt).min()
            let wait = soonest.map { max(1, $0.timeIntervalSinceNow + 1) } ?? ceiling
            try? await Task.sleep(nanoseconds: UInt64(min(wait, ceiling) * Double(NSEC_PER_SEC)))
            guard !Task.isCancelled else { break }
            await channelsViewModel.load()
        }
    }
}

/// The tvOS hero's frame fitted to an iPad, portrait or landscape.
struct PadHeroMetrics {
    /// tvOS sizes scaled the way the rest of the iPad UI scales them
    /// (`MobileTypography`: 28 -> 17, 24 -> 15, 40 -> 22).
    static let scale: CGFloat = 0.6
    /// The tvOS hero is 32:9 of a 1800pt content column: 506pt of a 1080pt
    /// screen. The iPad hero takes the same share of its screen's height.
    static let screenShare: CGFloat = (1800.0 * 9 / 32) / 1080

    let height: CGFloat

    init(proxy: GeometryProxy) {
        let screenHeight = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        // Capped at 16:9 of the width: any taller and a backdrop (fitted, never
        // cropped, as on tvOS) could no longer fill it top to bottom. That cap
        // is what applies in portrait; landscape gets the full share.
        height = min(screenHeight * Self.screenShare, proxy.size.width * 9 / 16)
    }

    /// The scroll content and the hero both start below the status bar; 48 is
    /// the tvOS overlap.
    var revealHeight: CGFloat {
        max(0, height - 48 * Self.scale)
    }

    var layout: HeroLayout {
        HeroLayout(
            scale: Self.scale,
            height: height,
            topInset: 0,
            widensImageToFillHeight: true,
            textTopGap: 40,
            accent: MobileColors.accent
        )
    }
}

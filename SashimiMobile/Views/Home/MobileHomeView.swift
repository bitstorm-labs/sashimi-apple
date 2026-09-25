import SwiftUI

struct MobileHomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var rowSettings = HomeRowSettings.shared
    @StateObject private var channelsViewModel = ChannelsViewModel()
    @State private var tunedChannel: TunedChannel?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileSpacing.xl) {
                if viewModel.isLoading && viewModel.continueWatchingItems.isEmpty {
                    loadingView
                } else {
                    contentView
                }
            }
            .padding(.vertical, MobileSpacing.md)
        }
        .background(MobileColors.background)
        .refreshable {
            await viewModel.loadContent()
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

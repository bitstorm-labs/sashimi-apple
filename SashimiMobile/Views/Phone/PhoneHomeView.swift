import SwiftUI

struct PhoneHomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var rowSettings = HomeRowSettings.shared
    @StateObject private var channelsViewModel = ChannelsViewModel()
    @State private var tunedChannel: TunedChannel?
    @ObservedObject private var sessionManager = SessionManager.shared
    @State private var showAddServer = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileSpacing.lg) {
                if viewModel.isLoading && viewModel.continueWatchingItems.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    contentView
                }
            }
            .padding(.vertical, MobileSpacing.sm)
        }
        .background(MobileColors.background)
        .navigationBarHidden(true)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 8) {
                // Logo taps open the server quick-switcher (phone equivalent
                // of the tvOS avatar menu).
                Menu {
                    ForEach(sessionManager.servers) { server in
                        Button {
                            Task { await sessionManager.switchServer(to: server.id) }
                        } label: {
                            if server.id == sessionManager.activeServerId {
                                Label(server.displayName, systemImage: "checkmark")
                            } else {
                                Text(server.displayName)
                            }
                        }
                    }
                    Divider()
                    Button {
                        showAddServer = true
                    } label: {
                        Label("Add Server…", systemImage: "plus")
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image("SidebarLogo")
                            .resizable().scaledToFit()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        Text("Sashimi")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(MobileColors.textPrimary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, MobileSpacing.md)
            .padding(.vertical, MobileSpacing.xs)
            .background(MobileColors.background)
        }
        .sheet(isPresented: $showAddServer) {
            MobileAddServerSheet()
        }
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

    @ViewBuilder
    private var contentView: some View {
        ForEach(rowSettings.rows.filter { $0.isEnabled }) { row in
            rowView(for: row)
        }

        if viewModel.continueWatchingItems.isEmpty && viewModel.libraries.isEmpty {
            ContentUnavailableView(
                "No Content",
                systemImage: "tv",
                description: Text("Start watching something to see it here.")
            )
            .frame(maxWidth: .infinity, minHeight: 300)
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
                    libraryNames: libNames,
                    cardWidth: PhoneSizing.continueWatchingWidth
                ) { item in
                    PhoneDetailView(item: item, libraryName: libNames[item.id])
                }
            }

        case .builtIn(.channels):
            if !channelsViewModel.cards.isEmpty {
                MobileChannelsRow(cards: channelsViewModel.cards, cardWidth: PhoneSizing.channelCardWidth) { card in
                    tuneToChannel(card)
                }
            }

        case .library(let libraryId, let libraryName):
            let library = viewModel.libraries.first(where: { $0.id == libraryId })
            MobileRecentlyAddedRow(
                libraryId: libraryId,
                libraryName: libraryName,
                collectionType: library?.collectionType,
                cardWidth: PhoneSizing.posterWidth
            ) { item in
                PhoneDetailView(item: item, libraryName: libraryName)
            }
        }
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

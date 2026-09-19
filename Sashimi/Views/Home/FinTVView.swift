import SwiftUI
import NukeUI

/// The FinTV screen: every channel, and what each is airing right now.
struct FinTVView: View {
    var onBackAtRoot: (() -> Void)?
    var focusNamespace: Namespace.ID?

    @StateObject private var viewModel = ChannelsViewModel()
    @State private var tuned: TunedChannel?
    @State private var tuningChannelID: String?

    private let columns = [GridItem(.adaptive(minimum: 460), spacing: 40)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("FinTV")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .padding(.horizontal, 80)
                    .padding(.top, 60)

                if viewModel.isLoading && viewModel.cards.isEmpty {
                    ProgressView()
                        .padding(.horizontal, 80)
                } else if viewModel.cards.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(viewModel.cards) { card in
                            ChannelCard_View(card: card, isTuning: tuningChannelID == card.id) {
                                tune(card)
                            }
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.bottom, 80)
                }
            }
        }
        .background(SashimiTheme.background)
        .task {
            await viewModel.load()
            // A channel moves on whether or not anyone is looking at this
            // screen, so a card rendered once is wrong within minutes: the
            // thumbnail still shows a finished programme and the countdown
            // keeps ticking past zero. Re-resolve while the screen is up.
            while !Task.isCancelled {
                // Wake when the soonest programme actually ends, not on a fixed
                // tick: a 30s poll shows a finished programme for up to half a
                // minute, which is exactly the moment a viewer is looking. The
                // 30s ceiling remains as a safety net, because the schedule can
                // be rebuilt underneath us when the library changes.
                let soonest = viewModel.cards.compactMap(\.endsAt).min()
                let wait = soonest.map { max(1, $0.timeIntervalSinceNow + 1) } ?? 30
                try? await Task.sleep(nanoseconds: UInt64(min(wait, 30) * Double(NSEC_PER_SEC)))
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.35)) { }
                await viewModel.load()
            }
        }
        .fullScreenCover(item: $tuned) { tuned in
            PlayerView(item: tuned.item, channelContext: tuned.context)
        }
        .onChange(of: tuned) { oldValue, newValue in
            // Coming back from a channel: the schedule moved on while it played,
            // so the cards are stale by definition.
            if oldValue != nil && newValue == nil {
                Task { await viewModel.load() }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.loadFailed ? "Couldn't reach the server" : "No channels yet")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(SashimiTheme.textPrimary)
            Text(viewModel.loadFailed
                 ? "FinTV needs the server to be reachable."
                 : "Channels are created in Jellyfin under Dashboard → Plugins → Channels.")
                .font(.system(size: 22))
                .foregroundStyle(SashimiTheme.textSecondary)
        }
        .padding(.horizontal, 80)
        .padding(.top, 40)
    }

    private func tune(_ card: ChannelCard) {
        guard tuningChannelID == nil else { return }
        tuningChannelID = card.id
        Task {
            defer { tuningChannelID = nil }
            guard let result = await viewModel.tuneIn(to: card.channel) else {
                // Went off air between rendering and pressing. Refresh so the
                // screen tells the truth rather than appearing to do nothing.
                await viewModel.load()
                return
            }
            guard let item = try? await JellyfinClient.shared.getItem(itemId: result.itemID) else {
                await viewModel.load()
                return
            }
            tuned = TunedChannel(item: item, context: result.context)
        }
    }
}

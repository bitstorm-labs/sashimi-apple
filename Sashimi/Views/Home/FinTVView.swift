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
        .task { await viewModel.load() }
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

/// A channel tile.
///
/// Sized and weighted like the other Home cards rather than inventing its own
/// scale: a row that does not match the ones above and below it reads as broken
/// even when every individual value is defensible.
struct ChannelCard_View: View {
    let card: ChannelCard
    var isTuning: Bool = false
    let onTune: () -> Void

    @FocusState private var isFocused: Bool

    private var nowText: String {
        guard let item = card.item else { return "—" }
        if item.type == .episode, let season = item.parentIndexNumber, let episode = item.indexNumber {
            return "\(item.seriesName ?? "") · S\(season)E\(episode)"
        }
        return item.name ?? "—"
    }

    var body: some View {
        Button(action: onTune) {
            VStack(alignment: .leading, spacing: 0) {
                artwork
                caption
            }
            .background(SashimiTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isFocused ? SashimiTheme.accent : .clear, lineWidth: 4)
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .opacity(card.isOffAir ? 0.5 : 1)
        .disabled(card.isOffAir || isTuning)
        .accessibilityLabel(card.isOffAir
            ? "\(card.channel.name), off air"
            : "\(card.channel.name), now airing \(nowText), \(card.minutesRemaining) minutes remaining")
    }

    private var artwork: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.65))

            if let item = card.item {
                LazyImage(url: JellyfinClient.shared.imageURL(
                    itemId: item.seriesId ?? item.id, imageType: "Backdrop", maxWidth: 900
                )) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.85)],
                startPoint: .center, endPoint: .bottom
            )

            if card.isOffAir {
                VStack(spacing: 10) {
                    Image(systemName: "power").font(.system(size: 44))
                    Text("OFF AIR").font(.system(size: 20, weight: .semibold))
                }
                .foregroundStyle(SashimiTheme.textSecondary)
            } else if isTuning {
                ProgressView().scaleEffect(1.4)
            } else {
                // How far into the programme a viewer joins — visible before
                // pressing, so missing the start is never a surprise after.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule().fill(SashimiTheme.accent)
                            .frame(width: max(4, geo.size.width * card.progress))
                    }
                }
                .frame(height: 6)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .frame(height: 260)
        .clipped()
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.channel.name)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(SashimiTheme.textPrimary)
                .lineLimit(1)

            if card.isOffAir {
                Text("Off air")
                    .font(.system(size: 22))
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .lineLimit(1)
            } else {
                Text(nowText)
                    .font(.system(size: 22))
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .lineLimit(1)
                Text("\(card.minutesRemaining) min left")
                    .font(.system(size: 20))
                    .foregroundStyle(SashimiTheme.textSecondary.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }
}

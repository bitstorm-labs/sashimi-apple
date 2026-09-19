import SwiftUI
import NukeUI

/// The Channels row on Home.
///
/// A card shows what the channel is airing rather than channel branding: a
/// channel's identity is whatever is on it right now, and showing the programme
/// is also the cheapest possible evidence that the schedule is actually running.
struct ChannelsRow: View {
    let cards: [ChannelCard]
    let onTune: (ChannelCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Channels")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(cards) { card in
                        ChannelCardView(card: card, onTune: onTune)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 12)
            }
        }
    }
}

private struct ChannelCardView: View {
    let card: ChannelCard
    let onTune: (ChannelCard) -> Void

    @FocusState private var isFocused: Bool

    private var subtitle: String {
        guard let item = card.item else { return "" }
        if let season = item.parentIndexNumber, let episode = item.indexNumber {
            return String(format: "S%02dE%02d", season, episode)
        }
        return item.name ?? ""
    }

    var body: some View {
        Button {
            onTune(card)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                artwork
                caption
            }
            .frame(width: 320)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        // An off-air channel stays in the row rather than disappearing: hiding
        // it would change the row's length through the day, moving whatever sits
        // under the viewer's thumb.
        .opacity(card.isOffAir ? 0.55 : 1)
        .disabled(card.isOffAir)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        card.isOffAir
            ? "\(card.channel.name), off air"
            : "\(card.channel.name), now airing \(card.item?.seriesName ?? card.item?.name ?? ""), \(card.minutesRemaining) minutes remaining"
    }

    @ViewBuilder
    private var artwork: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.6))

            if let item = card.item {
                LazyImage(url: JellyfinClient.shared.imageURL(itemId: item.id, imageType: "Primary", maxWidth: 640)) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                }
            }

            if card.isOffAir {
                VStack(spacing: 8) {
                    Image(systemName: "power")
                        .font(.system(size: 36))
                    Text("OFF AIR")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.secondary)
            } else {
                // How far through the programme the viewer would be joining.
                // Shown before they press OK, because "you will miss the start"
                // should not be a surprise discovered after playback begins.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.25))
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * card.progress)
                    }
                }
                .frame(height: 4)
            }
        }
        .frame(width: 320, height: 180)
        .clipped()
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.channel.name.uppercased())
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if card.isOffAir {
                Text("Off air")
                    .font(.callout)
                    .lineLimit(1)
            } else {
                Text(card.item?.seriesName ?? card.item?.name ?? "—")
                    .font(.callout)
                    .lineLimit(1)

                Text(subtitle.isEmpty
                     ? "\(card.minutesRemaining)m left"
                     : "\(subtitle) · \(card.minutesRemaining)m left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

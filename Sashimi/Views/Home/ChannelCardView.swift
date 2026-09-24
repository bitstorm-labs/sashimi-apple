import SwiftUI
import NukeUI

/// A channel tile.
///
/// The channel name is a badge rather than the heading: it identifies the
/// channel, but what a viewer is choosing between is the programme, so the
/// programme's title, rating and synopsis take the text area.
struct ChannelCard_View: View {
    let card: ChannelCard
    var isTuning: Bool = false
    let onTune: () -> Void

    @FocusState private var isFocused: Bool

    private var title: String {
        guard let item = card.item else { return card.channel.name }
        if item.type == .episode { return item.seriesName ?? item.name ?? "—" }
        return item.name ?? "—"
    }

    /// Year · rating · certificate · runtime, skipping whatever is missing so a
    /// sparse item does not render a line of orphaned separators.
    private var metadata: String {
        guard let item = card.item else { return "" }
        var parts: [String] = []
        if item.type == .episode, !item.hasDatedEpisodeNumbers,
           let season = item.parentIndexNumber, let episode = item.indexNumber {
            parts.append("S\(season)E\(episode)")
        }
        if let year = item.productionYear { parts.append(String(year)) }
        if let rating = item.communityRating { parts.append(String(format: "★ %.1f", rating)) }
        if let certificate = item.officialRating { parts.append(certificate) }
        if let runtime = DateFormatting.formatRuntime(item.runTimeTicks) { parts.append(runtime) }
        return parts.joined(separator: " · ")
    }

    private var synopsis: String {
        card.item?.overview ?? card.channel.description ?? ""
    }

    private var nextTitle: String? {
        guard let next = card.nextItem else { return nil }
        if next.type == .episode { return next.seriesName ?? next.name }
        return next.name
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
                    // A faint edge when unfocused: without it the cards are
                    // flat panels of the same colour as each other and read as
                    // one strip rather than separate channels.
                    .stroke(isFocused ? SashimiTheme.focus : .white.opacity(0.10),
                            lineWidth: isFocused ? 4 : 1)
            )
            .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 15)
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .opacity(card.isOffAir ? 0.5 : 1)
        .disabled(card.isOffAir || isTuning)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.isOffAir
            ? "\(card.channel.name), off air"
            : "\(card.channel.name), now airing \(title)")
    }

    // MARK: - Artwork

    private var artwork: some View {
        ZStack(alignment: .topLeading) {
            // The backdrop is an overlay on the placeholder, not a sibling in
            // this stack. At aspectRatio(.fill) an image reports the size that
            // COVERS the proposal — 280 x 16/9 = 498pt for a 16:9 backdrop — and
            // a ZStack takes its size from the largest sibling, so the card drew
            // 58pt wider than the 440pt slot the row gave it, overflowed into
            // its neighbours and swallowed the gap between them. A flexible
            // frame does not save you here: maxWidth grows a frame to the
            // proposal, it never shrinks a child that reports larger. An overlay
            // is sized by its host and cannot feed its size back up.
            Rectangle()
                .fill(Color.black.opacity(0.65))
                .overlay {
                    if let item = card.item {
                        let art = item.channelArtwork
                        LazyImage(url: JellyfinClient.shared.imageURL(
                            itemId: art.itemId, imageType: art.imageType, maxWidth: 900
                        )) { state in
                            if let image = state.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            }
                        }
                        // Crossfade when the programme changes, so a rollover
                        // reads as the channel moving on rather than the card
                        // glitching.
                        .id(item.id)
                        .transition(.opacity)
                    }
                }

            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .black.opacity(0.9)],
                startPoint: .top, endPoint: .bottom
            )

            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    channelBadge
                    Spacer()
                    if !card.isOffAir { livePill }
                }
                Spacer()
                if card.isOffAir {
                    offAirMark
                } else if isTuning {
                    ProgressView().scaleEffect(1.3)
                } else {
                    SashimiProgressBar(progress: card.progress, height: 5, useGradient: true)
                }
            }
            .padding(24)
        }
        .frame(height: 280)
        .clipped()
    }

    private var channelBadge: some View {
        // The channel number leads, the way a cable box labels a station.
        HStack(spacing: 8) {
            if card.channel.logo != nil {
                ChannelLogoView(channelId: card.channel.id, logo: card.channel.logo, mono: true, size: 24)
            }
            Text(card.channel.number.map { "\($0) · \(card.channel.name.uppercased())" } ?? card.channel.name.uppercased())
                .font(.system(size: 18, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(.black.opacity(0.6)))
        .overlay(Capsule().stroke(.white.opacity(0.28), lineWidth: 1))
    }

    private var livePill: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text("LIVE")
                .font(.system(size: 15, weight: .bold))
                .tracking(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.6)))
    }

    private var offAirMark: some View {
        HStack(spacing: 10) {
            Image(systemName: "power").font(.system(size: 22))
            Text("OFF AIR").font(.system(size: 18, weight: .semibold))
        }
        .foregroundStyle(SashimiTheme.textSecondary)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Text

    private var caption: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.isOffAir ? card.channel.name : title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(SashimiTheme.textPrimary)
                .lineLimit(1)

            if card.isOffAir {
                Text(card.channel.description ?? "Back later")
                    .font(.system(size: 20))
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .lineLimit(2)
            } else {
                if !metadata.isEmpty {
                    Text(metadata)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(SashimiTheme.textSecondary)
                        .lineLimit(1)
                }

                Text(synopsis)
                    .font(.system(size: 19))
                    .foregroundStyle(SashimiTheme.textSecondary.opacity(0.85))
                    .lineLimit(2)
                    .frame(height: 50, alignment: .top)

                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            // Driven off a clock rather than the fetch, so the countdown ticks
            // every second without asking the server anything.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(card.timeRemaining(at: context.date))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SashimiTheme.accent)
                    .monospacedDigit()
            }

            Spacer()

            if let next = nextTitle {
                HStack(spacing: 6) {
                    Text("NEXT")
                        .font(.system(size: 14, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(SashimiTheme.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SashimiTheme.textTertiary)
                    Text(next)
                        .font(.system(size: 17))
                        .foregroundStyle(SashimiTheme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 220, alignment: .trailing)
            }
        }
    }
}

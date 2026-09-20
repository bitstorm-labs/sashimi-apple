import SwiftUI
import NukeUI

/// The FinTV row on the mobile Home.
///
/// The card carries the same information as the tvOS one — channel badge, live
/// state, progress through the current programme, title, metadata, synopsis,
/// countdown and what is next — at a size a phone can hold. Touch replaces
/// focus, so there are no focus rings or scale effects; the card is simply a
/// button.
struct MobileChannelsRow: View {
    let cards: [ChannelCard]
    var cardWidth: CGFloat = 300
    let onTune: (ChannelCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text("FinTV")
                .font(.title2.bold())
                .foregroundStyle(MobileColors.textPrimary)
                .padding(.horizontal, MobileSpacing.md)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MobileSpacing.md) {
                    ForEach(cards) { card in
                        MobileChannelCard(card: card, width: cardWidth) { onTune(card) }
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
            }
        }
    }
}

struct MobileChannelCard: View {
    let card: ChannelCard
    let width: CGFloat
    let onTune: () -> Void

    private var artworkHeight: CGFloat { width * 9 / 16 }

    private var title: String {
        guard let item = card.item else { return card.channel.name }
        if item.type == .episode { return item.seriesName ?? item.name ?? "—" }
        return item.name ?? "—"
    }

    /// Year, rating, certificate and runtime, skipping whatever is missing so a
    /// sparse item does not render a line of orphaned separators.
    private var metadata: String {
        guard let item = card.item else { return "" }
        var parts: [String] = []
        if item.type == .episode, let season = item.parentIndexNumber, let episode = item.indexNumber {
            parts.append("S\(season)E\(episode)")
        }
        if let year = item.productionYear { parts.append(String(year)) }
        if let rating = item.communityRating { parts.append(String(format: "★ %.1f", rating)) }
        if let certificate = item.officialRating { parts.append(certificate) }
        if let runtime = DateFormatting.formatRuntime(item.runTimeTicks) { parts.append(runtime) }
        return parts.joined(separator: " · ")
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
            .frame(width: width)
            .background(MobileColors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .opacity(card.isOffAir ? 0.5 : 1)
        .disabled(card.isOffAir)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.isOffAir
            ? "\(card.channel.name), off air"
            : "\(card.channel.name), now airing \(title)")
    }

    // MARK: - Artwork

    private var artwork: some View {
        ZStack(alignment: .topLeading) {
            // The backdrop is an overlay on a flexible host, never a sibling in
            // this stack: at aspectRatio(.fill) an image reports the size that
            // COVERS the proposal, and a ZStack adopts its largest sibling, so a
            // sibling image makes the card wider than the width it was given.
            Rectangle()
                .fill(Color.black.opacity(0.65))
                .overlay {
                    if let item = card.item {
                        LazyImage(url: JellyfinClient.shared.imageURL(
                            itemId: item.seriesId ?? item.id, imageType: "Backdrop", maxWidth: 800
                        )) { state in
                            if let image = state.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            }
                        }
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
                } else {
                    MobileProgressBar(progress: card.progress)
                }
            }
            .padding(MobileSpacing.sm)
        }
        .frame(height: artworkHeight)
        .clipped()
    }

    private var channelBadge: some View {
        Text(card.channel.name.uppercased())
            .font(.caption.bold())
            .tracking(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(.black.opacity(0.6)))
            .overlay(Capsule().stroke(.white.opacity(0.28), lineWidth: 1))
    }

    private var livePill: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.red).frame(width: 6, height: 6)
            Text("LIVE").font(.caption2.bold()).tracking(0.6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.6)))
    }

    private var offAirMark: some View {
        HStack(spacing: 6) {
            Image(systemName: "power")
            Text("OFF AIR").font(.caption.weight(.semibold))
        }
        .foregroundStyle(MobileColors.textSecondary)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Text

    private var caption: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(card.isOffAir ? card.channel.name : title)
                .font(.subheadline.bold())
                .foregroundStyle(MobileColors.textPrimary)
                .lineLimit(1)

            if card.isOffAir {
                Text(card.channel.description ?? "Back later")
                    .font(.caption)
                    .foregroundStyle(MobileColors.textSecondary)
                    .lineLimit(2)
            } else {
                if !metadata.isEmpty {
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(MobileColors.textSecondary)
                        .lineLimit(1)
                }

                Text(card.item?.overview ?? card.channel.description ?? "")
                    .font(.caption)
                    .foregroundStyle(MobileColors.textSecondary.opacity(0.85))
                    .lineLimit(2)
                    .frame(height: 30, alignment: .top)

                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MobileSpacing.sm)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // Driven off a clock rather than the fetch, so the countdown ticks
            // every second without asking the server anything.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(card.timeRemaining(at: context.date))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MobileColors.accent)
                    .monospacedDigit()
            }

            Spacer()

            if let next = nextTitle {
                HStack(spacing: 4) {
                    Text("NEXT")
                        .font(.caption2.bold())
                        .foregroundStyle(MobileColors.textSecondary.opacity(0.7))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(MobileColors.textSecondary.opacity(0.7))
                    Text(next)
                        .font(.caption2)
                        .foregroundStyle(MobileColors.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: width * 0.5, alignment: .trailing)
            }
        }
    }
}

/// Progress through the current programme. Takes 0–1, matching every other
/// progress surface in the app.
private struct MobileProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule()
                    .fill(MobileColors.accent)
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

import AVFoundation
import SwiftUI

// MARK: - Metrics

/// Sizes for the player's top info bar. tvOS keeps its original ten-foot
/// sizes; iPad and iPhone draw the same bar smaller. Every number the bar
/// uses lives here so the platforms differ only in scale, never in content.
struct PlayerInfoBarMetrics: Equatable {
    var rowSpacing: CGFloat
    var avatarSize: CGFloat
    var avatarSpacing: CGFloat
    var seriesNameFont: CGFloat
    var logoMaxHeight: CGFloat
    var logoMaxWidth: CGFloat
    var titleFont: CGFloat
    var titleSpacing: CGFloat
    var metaFont: CGFloat
    var metaSpacing: CGFloat
    var chipDot: CGFloat
    var chipSpacing: CGFloat
    var clockFont: CGFloat

    /// Apple TV: the sizes the tvOS player has always used.
    static let tv = PlayerInfoBarMetrics(
        rowSpacing: 12, avatarSize: 80, avatarSpacing: 20, seriesNameFont: 28,
        logoMaxHeight: 100, logoMaxWidth: 500, titleFont: 36, titleSpacing: 10,
        metaFont: 24, metaSpacing: 8, chipDot: 10, chipSpacing: 8, clockFont: 42
    )

    static let pad = PlayerInfoBarMetrics(
        rowSpacing: 6, avatarSize: 40, avatarSpacing: 10, seriesNameFont: 16,
        logoMaxHeight: 44, logoMaxWidth: 240, titleFont: 20, titleSpacing: 6,
        metaFont: 13, metaSpacing: 5, chipDot: 7, chipSpacing: 5, clockFont: 22
    )

    static let phone = PlayerInfoBarMetrics(
        rowSpacing: 4, avatarSize: 30, avatarSpacing: 8, seriesNameFont: 14,
        logoMaxHeight: 30, logoMaxWidth: 160, titleFont: 16, titleSpacing: 5,
        metaFont: 11, metaSpacing: 4, chipDot: 6, chipSpacing: 4, clockFont: 17
    )
}

/// Which piece of series art the bar wants. Each platform supplies its own
/// image view (tvOS keeps its placeholder behaviour; iOS falls back to text).
enum PlayerInfoBarArtwork {
    /// A regular series: its Logo image.
    case seriesLogo(seriesId: String)
    /// A YouTube channel (Pinchflat): its round Primary avatar.
    case channelAvatar(seriesId: String)
}

// MARK: - Text helpers

/// The strings the info bar shows, kept apart from the view so both players
/// (and tests) format them the same way.
enum PlayerInfoText {
    /// Above these, a "season"/"episode" is a YouTube upload year and counter
    /// rather than real TV numbering.
    static let maxPlausibleSeason = 2100
    static let maxPlausibleEpisode = 1000

    static func isYouTubeEpisode(_ item: BaseItemDto) -> Bool {
        guard item.type == .episode else { return false }
        if item.path?.lowercased().contains("youtube") == true { return true }
        // Pinchflat encodes the upload year as the season and a running
        // counter as the episode, so values far outside real TV numbering are
        // the tell. Named rather than inline so the intent survives.
        if let season = item.parentIndexNumber, let episode = item.indexNumber {
            if season > maxPlausibleSeason || episode > maxPlausibleEpisode { return true }
        }
        return false
    }

    static func releaseDate(for item: BaseItemDto) -> String? {
        if let premiereDateStr = item.premiereDate,
           let formatted = DateFormatting.formatLongDate(premiereDateStr) {
            return formatted
        }
        if let year = item.productionYear {
            return String(year)
        }
        return nil
    }

    /// "Finishes at 21:40": now plus the time left, at the current speed.
    static func finishesAt(player: AVPlayer?, now: Date) -> String? {
        guard let player,
              let duration = player.currentItem?.duration,
              duration.isValid && !duration.isIndefinite,
              duration.seconds > 0 else { return nil }
        return finishesAt(
            remaining: duration.seconds - player.currentTime().seconds,
            rate: player.rate,
            now: now
        )
    }

    static func finishesAt(remaining: Double, rate: Float, now: Date) -> String? {
        guard remaining > 0 else { return nil }
        let speed = rate > 0 ? Double(rate) : 1.0
        return "Finishes at " + ClockTime.time(now.addingTimeInterval(remaining / speed))
    }

    static func chipText(for info: PlayerViewModel.StreamInfo) -> String {
        var text = info.label
        if let detail = info.detail {
            text += " → \(detail)"
        }
        if let reason = info.reason {
            text += " (\(reason))"
        }
        return text
    }

    static func chipColor(for method: PlayerViewModel.StreamInfo.Method) -> Color {
        switch method {
        case .directPlay: return .green
        case .directStream: return .yellow
        case .transcode: return .orange
        }
    }
}

// MARK: - Stream info chip

/// The delivery chip: a coloured dot (green Original, yellow remux, orange
/// Converted) and the label, plus the transcode target and reason if any.
struct StreamInfoChip: View {
    let info: PlayerViewModel.StreamInfo
    var dotSize: CGFloat = 10
    var spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: spacing) {
            Circle()
                .fill(PlayerInfoText.chipColor(for: info.method))
                .frame(width: dotSize, height: dotSize)
            Text(PlayerInfoText.chipText(for: info))
        }
    }
}

// MARK: - Info bar

/// The player's top info bar, shared by Apple TV and iPhone/iPad: series logo
/// (or a channel avatar for YouTube), "S2:E7 · Title", then release date ·
/// resolution · Finishes at · delivery chip, and the clock on the right.
struct PlayerInfoBar<Artwork: View>: View {
    let item: BaseItemDto
    let resolution: String?
    let finishesAt: String?
    let streamInfo: PlayerViewModel.StreamInfo?
    let clock: String
    var metrics: PlayerInfoBarMetrics = .tv
    @ViewBuilder let artwork: (PlayerInfoBarArtwork) -> Artwork

    private var isYouTubeEpisode: Bool { PlayerInfoText.isYouTubeEpisode(item) }
    private var releaseDate: String? { PlayerInfoText.releaseDate(for: item) }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                seriesArt
                titleLine
                metaLine
            }
            Spacer()
            Text(clock)
                .font(.system(size: metrics.clockFont, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
    }

    // Series logo or channel art
    @ViewBuilder private var seriesArt: some View {
        if item.type == .episode, let seriesId = item.seriesId {
            if isYouTubeEpisode {
                HStack(spacing: metrics.avatarSpacing) {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: metrics.avatarSize, height: metrics.avatarSize)
                        .overlay(
                            artwork(.channelAvatar(seriesId: seriesId))
                                .clipShape(Circle())
                        )
                    if let seriesName = item.seriesName {
                        Text(seriesName)
                            .font(.system(size: metrics.seriesNameFont, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            } else {
                artwork(.seriesLogo(seriesId: seriesId))
                    .frame(maxHeight: metrics.logoMaxHeight, alignment: .leading)
                    .frame(maxWidth: metrics.logoMaxWidth, alignment: .leading)
                    .clipped()
            }
        }
    }

    // Title with S#:E# prefix for episodes
    private var titleLine: some View {
        HStack(spacing: metrics.titleSpacing) {
            if !isYouTubeEpisode, let season = item.parentIndexNumber, let episode = item.indexNumber {
                Text("S\(season):E\(episode)")
                    .font(.system(size: metrics.titleFont, weight: .bold))
                    .foregroundStyle(.white)
                Text("·")
                    .font(.system(size: metrics.titleFont, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(item.type == .episode ? item.name : item.displayTitle)
                .font(.system(size: metrics.titleFont, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    // Release date, quality, finish time, and delivery method. On a screen
    // too narrow for all of it (an iPhone held upright) the date goes first,
    // then the finish time, rather than wrapping every item onto two lines.
    // Where it fits, which is always on a TV, the first line is the one shown.
    private var metaLine: some View {
        ViewThatFits(in: .horizontal) {
            metaItems(showsDate: true, showsFinish: true)
            metaItems(showsDate: false, showsFinish: true)
            metaItems(showsDate: false, showsFinish: false)
        }
        .font(.system(size: metrics.metaFont, weight: .medium))
        .foregroundStyle(.white.opacity(0.6))
    }

    private func metaItems(showsDate: Bool, showsFinish: Bool) -> some View {
        let dateText = showsDate ? releaseDate : nil
        let finishText = showsFinish ? finishesAt : nil
        return HStack(spacing: metrics.metaSpacing) {
            if let dateText {
                Text(dateText)
            }
            if let resolution {
                if dateText != nil {
                    Text("·")
                        .foregroundStyle(.white.opacity(0.4))
                }
                Text(resolution)
            }
            if let finishText {
                if dateText != nil || resolution != nil {
                    Text("·")
                        .foregroundStyle(.white.opacity(0.4))
                }
                Text(finishText)
            }
            if let streamInfo {
                Text("·")
                    .foregroundStyle(.white.opacity(0.4))
                StreamInfoChip(info: streamInfo, dotSize: metrics.chipDot, spacing: metrics.chipSpacing)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

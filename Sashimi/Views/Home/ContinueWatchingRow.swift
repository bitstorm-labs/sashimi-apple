import SwiftUI

struct ContinueWatchingRow: View {
    let items: [MediaItem]
    var libraryNames: [String: String] = [:]  // rawId -> Library name mapping
    let onSelect: (MediaItem) -> Void
    var onPlay: ((MediaItem) -> Void)?  // Optional: immediate playback on Play button

    private func isYouTube(_ item: MediaItem) -> Bool {
        guard let libraryName = libraryNames[item.rawId] else { return false }
        return libraryName.lowercased().contains("youtube")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Continue Watching")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(SashimiTheme.textPrimary)
                .padding(.horizontal, 80)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 40) {
                    ForEach(items) { item in
                        ContinueWatchingCard(
                            item: item,
                            isYouTube: isYouTube(item),
                            onSelect: { onSelect(item) },
                            onPlayPause: onPlay != nil ? { onPlay?(item) } : nil
                        )
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 20)
            }
        }
    }
}

struct ContinueWatchingCard: View {
    let item: MediaItem
    var isYouTube: Bool = false  // Whether this is YouTube content
    let onSelect: () -> Void
    var onPlayPause: (() -> Void)?  // Optional: immediate playback on Play/Pause button

    @FocusState private var isFocused: Bool

    // Check if parent series has backdrop images (regular shows have it, YouTube doesn't)
    private var seriesHasBackdrop: Bool {
        if let tags = item.parentBackdropImageTags, !tags.isEmpty {
            return true
        }
        return false
    }

    private var imageId: String {
        // For episodes with backdrops (regular shows), use series backdrop
        // For episodes without backdrops (YouTube), use episode's own thumbnail
        if item.type == .episode {
            return seriesHasBackdrop ? (item.seriesId ?? item.rawId) : item.rawId
        }
        return item.rawId
    }

    private var imageType: String {
        switch item.type {
        case .episode:
            return seriesHasBackdrop ? "Backdrop" : "Primary"
        case .video:
            return "Primary"
        default:
            return "Backdrop"
        }
    }

    // Fallback image types for when primary choice fails
    private var fallbackImageTypes: [String] {
        if item.type == .episode && !seriesHasBackdrop {
            return ["Thumb", "Backdrop"]
        }
        return ["Primary", "Thumb"]
    }

    private var displayTitle: String {
        switch item.type {
        case .movie, .video:
            return item.title
        case .series:
            return item.title.cleanedYouTubeTitle
        case .episode:
            return (item.seriesName ?? item.title).cleanedYouTubeTitle
        default:
            return item.title
        }
    }

    private var episodeInfoString: String {
        // For YouTube, show date instead of S/E
        if isYouTube, let dateStr = item.premiereDate {
            return "\(formatDate(dateStr)) - \(item.title)"
        }
        let season = item.seasonNumber ?? 1
        let episode = item.episodeNumber ?? 1
        return "S\(season):E\(episode) - \(item.title)"
    }

    private func formatDate(_ isoDate: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "M-d-yyyy"
            return displayFormatter.string(from: date)
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "M-d-yyyy"
            return displayFormatter.string(from: date)
        }
        return ""
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .bottom) {
                    AsyncItemImage(
                        itemId: imageId,
                        imageType: imageType,
                        maxWidth: 600,
                        fallbackImageTypes: fallbackImageTypes
                    )
                    .frame(width: 440, height: 248)
                    .overlay(
                        LinearGradient(
                            colors: [.clear, .clear, .black.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "play.fill")
                                .font(.caption)
                                .foregroundStyle(SashimiTheme.accent)

                            Text(formatRemainingTime())
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(SashimiTheme.textSecondary)
                        }

                        SashimiProgressBar(progress: item.progressPercent, height: 5, useGradient: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .frame(width: 440, alignment: .leading)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isFocused ? SashimiTheme.accent : .clear, lineWidth: 4)
                )
                .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 15)

                VStack(alignment: .leading, spacing: 4) {
                    MarqueeText(
                        text: displayTitle,
                        isScrolling: isFocused,
                        height: 34
                    )
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(SashimiTheme.textPrimary)

                    if item.type == .episode {
                        MarqueeText(
                            text: episodeInfoString,
                            isScrolling: isFocused,
                            height: 26
                        )
                        .font(.system(size: 20))
                        .foregroundStyle(SashimiTheme.textSecondary)
                    } else if let year = item.year {
                        Text(String(year))
                            .font(.system(size: 20))
                            .foregroundStyle(SashimiTheme.textTertiary)
                    }
                }
                .frame(width: 440, alignment: .leading)
            }
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Double-tap to resume playback, or press Play to start immediately")
        .onPlayPauseCommand {
            if let playPause = onPlayPause {
                playPause()
            }
        }
    }

    private var accessibilityDescription: String {
        var parts: [String] = [displayTitle]

        if item.type == .episode {
            parts.append(episodeInfoString)
        }

        parts.append(formatRemainingTime())

        return parts.joined(separator: ", ")
    }

    private func formatRemainingTime() -> String {
        guard let durationTicks = item.durationTicks else { return "" }
        let positionTicks = item.positionTicks ?? 0
        let remaining = durationTicks - positionTicks
        let seconds = remaining / 10_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m left"
        }
        return "\(minutes)m left"
    }
}

// MARK: - Continue Watching Detail View (See All)

struct ContinueWatchingDetailView: View {
    let items: [MediaItem]
    let onSelect: (MediaItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    // Header
                    Text("Continue Watching")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .padding(.horizontal, 80)
                        .padding(.top, 40)

                    // Grid of items
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 420, maximum: 480), spacing: 40)
                    ], spacing: 40) {
                        ForEach(items) { item in
                            ContinueWatchingCard(item: item) {
                                onSelect(item)
                            }
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.bottom, 60)
                }
            }
        }
        .onExitCommand {
            dismiss()
        }
    }
}

import SwiftUI
import NukeUI

// Row building blocks for DownloadsListView. Each row draws its own content
// only; the list decides taps, swipes and selection.

// MARK: - Grouping

/// A show's finished episodes under one header, or a single movie.
struct DownloadGroup: Identifiable {
    let id: String
    let items: [DownloadedItem]
    var isShow: Bool { items.first?.seriesId != nil }

    /// Groups episodes by show (per server), keeping the list's newest-first
    /// order between groups and episode order within a show.
    static func groups(_ completed: [DownloadedItem]) -> [DownloadGroup] {
        var order: [String] = []
        var byKey: [String: [DownloadedItem]] = [:]
        for item in completed {
            let key = item.seriesId.map { "\(item.serverID ?? "legacy"):series:\($0)" } ?? item.recordID
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        return order.map { key in
            let items = byKey[key] ?? []
            let sorted = items.first?.seriesId == nil ? items : items.sorted {
                ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
            }
            return DownloadGroup(id: key, items: sorted)
        }
    }
}

extension DownloadedItem {
    var watchCandidate: DownloadWatchCandidate {
        DownloadWatchCandidate(recordID: recordID, sizeBytes: sizeBytes, isComplete: isComplete)
    }

    /// "42 min" or "1h 38m", as on the detail pages.
    var runtimeLabel: String? {
        guard let ticks = runTimeTicks, ticks > 0 else { return nil }
        let seconds = ticks / 10_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes) min"
    }
}

/// "[720p]  42 min · TMDb 7.6 · 777 MB": the quality as the poster cards'
/// chip, then runtime, community rating (when known) and size.
struct DownloadMetadataLine: View {
    let item: DownloadedItem
    let communityRating: Double?

    var body: some View {
        HStack(spacing: 6) {
            QualityBadge(
                label: item.downloadQuality.shortLabel,
                fontSize: 10,
                horizontalPadding: 5,
                verticalPadding: 2,
                cornerRadius: 4
            )

            HStack(spacing: 4) {
                if let runtime = item.runtimeLabel {
                    Text(runtime)
                    separator
                }
                if let communityRating, communityRating > 0 {
                    Image("TMDBLogo")
                        .resizable().scaledToFit()
                        .frame(height: 10)
                        .accessibilityLabel("TMDb")
                    Text(String(format: "%.1f", communityRating))
                    separator
                }
                Text(item.formattedSize)
            }
            .font(.system(size: 12))
            .foregroundStyle(MobileColors.textTertiary)
            .lineLimit(1)
        }
    }

    private var separator: some View {
        Text("·").accessibilityHidden(true)
    }
}

// MARK: - Artwork

@MainActor
enum DownloadArtwork {
    static func serverImageURL(itemId: String, serverID: String?, maxWidth: Int) -> URL? {
        let serverURL: URL?
        if let serverID {
            serverURL = SessionManager.shared.servers.first(where: { $0.id == serverID })?.url
        } else {
            serverURL = SessionManager.shared.serverURL
        }
        guard let serverURL else { return nil }
        return serverURL
            .appendingPathComponent("Items/\(itemId)/Images/Primary")
            .appending(queryItems: [URLQueryItem(name: "maxWidth", value: "\(maxWidth)")])
    }
}

/// The 60x90 poster (the series poster for episodes).
struct DownloadPoster: View {
    let item: DownloadedItem

    var body: some View {
        if let url = DownloadArtwork.serverImageURL(
            itemId: item.seriesId ?? item.itemId, serverID: item.serverID, maxWidth: 200
        ) {
            LazyImage(request: SashimiImagePipeline.request(url: url, serverID: item.serverID)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
            .frame(width: 60, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(MobileColors.background)
            .frame(width: 60, height: 90)
            .overlay {
                Image(systemName: "film")
                    .font(.system(size: 16))
                    .foregroundStyle(MobileColors.textTertiary)
            }
    }
}

/// The episode's own still, so a show's downloads are told apart at a
/// glance. The file saved with the download is preferred (it works
/// offline); the server copy covers downloads whose image never arrived.
struct DownloadEpisodeThumbnail: View {
    let item: DownloadedItem

    var body: some View {
        let url = OfflineImageHelper.thumbnailURL(for: item.itemId, serverID: item.serverID)
            ?? DownloadArtwork.serverImageURL(itemId: item.itemId, serverID: item.serverID, maxWidth: 320)
        Group {
            if let url {
                LazyImage(request: SashimiImagePipeline.request(url: url, serverID: item.serverID)) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(MobileColors.background)
                    }
                }
            } else {
                Rectangle().fill(MobileColors.background)
            }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Progress along the artwork's bottom edge and the watched check in its
/// top-right corner — the same marks as the show pages' episode cards.
struct DownloadWatchMarks: ViewModifier {
    let state: DownloadWatchState
    var checkSize: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if state.progress > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(MobileColors.progressBackground)
                            Rectangle()
                                .fill(MobileColors.accent)
                                .frame(width: geo.size.width * CGFloat(state.progress))
                        }
                    }
                    .frame(height: 3)
                    .accessibilityLabel("\(Int(state.progress * 100))% watched")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                if state.isPlayed {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, Color(red: 0.29, green: 0.73, blue: 0.47))
                        .font(.system(size: checkSize))
                        .padding(4)
                        .accessibilityLabel("Watched")
                }
            }
    }
}

/// Edit mode's selection circle.
struct DownloadSelectionMark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22))
            .foregroundStyle(isSelected ? MobileColors.accent : MobileColors.textTertiary)
            .accessibilityLabel(isSelected ? "Selected" : "Not selected")
    }
}

// MARK: - Completed rows

/// An episode under its show header (thumbnail) or a movie (poster).
struct CompletedDownloadRow: View {
    let item: DownloadedItem
    let isEpisode: Bool
    let watchState: DownloadWatchState
    /// Cached from the server; nil when unknown or ratings are hidden.
    var communityRating: Double?
    let isEditing: Bool
    let isSelected: Bool
    /// Made by the pre-fix transcode URL (1 kbps video): offer to replace it.
    var needsRedownload = false
    var onRedownload: () -> Void = {}
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: MobileSpacing.md) {
            if isEditing {
                DownloadSelectionMark(isSelected: isSelected)
            }

            if isEpisode {
                DownloadEpisodeThumbnail(item: item)
                    .modifier(DownloadWatchMarks(state: watchState))
            } else {
                DownloadPoster(item: item)
                    .modifier(DownloadWatchMarks(state: watchState, checkSize: 14))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(isEpisode ? episodeLabel : item.displayTitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(isEpisode ? 1 : 2)

                if !isEpisode, item.seriesName != nil {
                    Text(item.name)
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textSecondary)
                        .lineLimit(1)
                }

                DownloadMetadataLine(item: item, communityRating: communityRating)

                if needsRedownload, !isEditing {
                    LowQualityDownloadBadge(onRedownload: onRedownload)
                }
            }

            Spacer(minLength: 0)

            // Downloads are for watching: play right here, from the local file,
            // instead of leaving to search for the title (iPad feedback).
            if !isEditing {
                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(MobileColors.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(item.displayTitle)")
            }
        }
        .padding(.horizontal, MobileSpacing.md)
        .padding(.vertical, isEpisode ? 10 : MobileSpacing.md)
        .contentShape(Rectangle())
    }

    private var episodeLabel: String {
        guard let season = item.seasonNumber, let episode = item.episodeNumber else { return item.name }
        return "S\(season):E\(episode) · \(item.name)"
    }
}

/// "Low quality file · Re-download": on downloads made before the transcode
/// fix, whose video was encoded at 1 kbps and cannot be watched.
struct LowQualityDownloadBadge: View {
    let onRedownload: () -> Void

    var body: some View {
        Button(action: onRedownload) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Low quality file · Re-download")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Low quality file. Re-download")
    }
}

/// The show's poster and name, with a way to its page (the seasons and
/// episodes that aren't downloaded live there) and a way to clear the
/// episodes already watched.
struct DownloadShowHeader: View {
    let episode: DownloadedItem
    let episodeCount: Int
    let watchedCount: Int
    let watchedBytes: Int64
    let showsGoToShow: Bool
    let isEditing: Bool
    let allSelected: Bool
    let onGoToShow: () -> Void
    let onRemoveWatched: () -> Void

    var body: some View {
        HStack(spacing: MobileSpacing.md) {
            if isEditing {
                DownloadSelectionMark(isSelected: allSelected)
            }

            DownloadPoster(item: episode)

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.seriesName ?? episode.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(1)
                Text(episodeCount == 1 ? "1 episode" : "\(episodeCount) episodes")
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textSecondary)

                if !isEditing, let seriesId = episode.seriesId {
                    KeepNextEpisodesHeaderControl(serverID: episode.serverID, seriesId: seriesId)
                }

                if watchedCount > 0 && !isEditing {
                    Button(action: onRemoveWatched) {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                            Text("Remove watched (\(ByteCountFormatter.string(fromByteCount: watchedBytes, countStyle: .file)))")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MobileColors.error.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            // The show page comes from the server; offline there is nothing to open.
            if showsGoToShow && !isEditing {
                Button(action: onGoToShow) {
                    HStack(spacing: 4) {
                        Text("Go to show")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MobileColors.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(MobileSpacing.md)
        .contentShape(Rectangle())
    }
}

// MARK: - Failed rows (the active row is in ActiveDownloadRow.swift)

struct FailedDownloadRow: View {
    let item: DownloadedItem
    /// "Retrying in 5 min" while an automatic retry is scheduled.
    var retryNote: String?
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: MobileSpacing.md) {
            DownloadPoster(item: item)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(1)

                Text(item.errorMessage ?? "Download failed")
                    .font(.system(size: 12))
                    .foregroundStyle(MobileColors.error)
                    .lineLimit(1)

                if let retryNote {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(retryNote)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(MobileColors.textSecondary)
                    .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(MobileColors.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry \(item.displayTitle)")

                Button(action: onDelete) {
                    Image(systemName: "trash.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(MobileColors.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(item.displayTitle)")
            }
        }
        .padding(MobileSpacing.md)
    }
}

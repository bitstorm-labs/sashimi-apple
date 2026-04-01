import SwiftUI

/// Bridge view that presents MediaDetailView from a MediaItem.
/// For Jellyfin items: fetches BaseItemDto and delegates to MediaDetailView.
/// For Plex items: shows a basic detail view using MediaItem data.
struct MediaItemDetailBridge: View {
    let mediaItem: MediaItem
    var forceYouTubeStyle: Bool = false

    @State private var baseItem: BaseItemDto?
    @State private var isLoading = true
    @State private var loadError = false
    @Environment(\.dismiss) private var dismiss

    private var server: (any MediaServer)? {
        ServerManager.shared.server(forId: mediaItem.serverId)
    }

    var body: some View {
        Group {
            if server?.serverType == .jellyfin {
                jellyfinDetail
            } else {
                plexDetail
            }
        }
        .task {
            await loadItem()
        }
    }

    @ViewBuilder
    private var jellyfinDetail: some View {
        if let baseItem {
            MediaDetailView(item: baseItem, forceYouTubeStyle: forceYouTubeStyle)
        } else if isLoading {
            loadingView
        } else {
            errorView
        }
    }

    @ViewBuilder
    private var plexDetail: some View {
        if isLoading {
            loadingView
        } else {
            PlexDetailView(item: mediaItem, server: server)
        }
    }

    private var loadingView: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()
            ProgressView().scaleEffect(1.5)
        }
    }

    private var errorView: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(SashimiTheme.textTertiary)
                Text("Failed to load item")
                    .foregroundStyle(SashimiTheme.textSecondary)
                Button("Dismiss") { dismiss() }
            }
        }
    }

    private func loadItem() async {
        isLoading = true
        if server?.serverType == .jellyfin {
            do {
                baseItem = try await JellyfinClient.shared.getItem(itemId: mediaItem.rawId)
            } catch {
                loadError = true
            }
        }
        // For Plex, we already have the MediaItem data — no additional fetch needed
        isLoading = false
    }
}

/// Basic detail view for Plex items
struct PlexDetailView: View {
    let item: MediaItem
    let server: (any MediaServer)?

    var body: some View {
        ZStack {
            // Backdrop
            if let server, let backdropId = item.backdropItemId {
                AsyncItemImage(
                    itemId: backdropId,
                    imageType: "Backdrop",
                    maxWidth: 1920,
                    contentMode: .fill,
                    server: server
                )
                .ignoresSafeArea()
                .overlay(
                    LinearGradient(
                        colors: [.clear, SashimiTheme.background.opacity(0.8), SashimiTheme.background],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Spacer().frame(height: 300)

                    // Title
                    Text(item.title)
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(SashimiTheme.textPrimary)

                    // Metadata row
                    HStack(spacing: 16) {
                        if let year = item.year {
                            Text(String(year))
                                .foregroundStyle(SashimiTheme.textSecondary)
                        }
                        if let rating = item.officialRating {
                            Text(rating)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(SashimiTheme.textTertiary))
                                .foregroundStyle(SashimiTheme.textSecondary)
                        }
                        if let duration = item.durationSeconds {
                            let hours = Int(duration) / 3600
                            let minutes = (Int(duration) % 3600) / 60
                            Text(hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m")
                                .foregroundStyle(SashimiTheme.textSecondary)
                        }
                        if let rating = item.communityRating {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption)
                                Text(String(format: "%.1f", rating))
                                    .foregroundStyle(SashimiTheme.textSecondary)
                            }
                        }
                    }
                    .font(.callout)

                    // Overview
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.body)
                            .foregroundStyle(SashimiTheme.textSecondary)
                            .lineLimit(6)
                    }

                    // Genres
                    if !item.genres.isEmpty {
                        Text(item.genres.joined(separator: " · "))
                            .font(.callout)
                            .foregroundStyle(SashimiTheme.textTertiary)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.bottom, 100)
            }
        }
    }
}

/// Bridge view that presents PlayerView from a MediaItem.
struct MediaItemPlayerBridge: View {
    let mediaItem: MediaItem
    var startFromBeginning: Bool = false

    @State private var baseItem: BaseItemDto?
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    private var server: (any MediaServer)? {
        ServerManager.shared.server(forId: mediaItem.serverId)
    }

    var body: some View {
        Group {
            if let baseItem {
                PlayerView(item: baseItem, startFromBeginning: startFromBeginning)
            } else if isLoading {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView().scaleEffect(1.5)
                }
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    Text("Failed to load")
                        .foregroundStyle(.white)
                }
            }
        }
        .task {
            if server?.serverType == .jellyfin {
                do {
                    baseItem = try await JellyfinClient.shared.getItem(itemId: mediaItem.rawId)
                } catch {}
            }
            // TODO: Plex playback support in Phase 4
            isLoading = false
        }
    }
}

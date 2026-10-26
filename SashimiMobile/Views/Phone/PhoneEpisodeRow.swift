import SwiftUI
import NukeUI

/// An episode as a row (iPhone): thumbnail with watched check and progress,
/// "E3 • Nov 8, 2024", name and runtime. The iPhone series page and season
/// page list episodes with it; long-press opens the episode's item menu.
struct PhoneEpisodeRow: View {
    let episode: BaseItemDto
    var isCurrentEpisode = false
    var isYouTube = false
    var serverID: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: MobileSpacing.sm) {
                thumbnail
                    .frame(width: 120, height: 68)
                    .offlineIndicator(itemId: episode.id, serverID: serverID, size: 14)
                    .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))
                    .currentEpisodeHighlight(isCurrentEpisode)

                VStack(alignment: .leading, spacing: 4) {
                    if !isYouTube, let epNum = episode.indexNumber {
                        HStack(spacing: 4) {
                            Text("E\(epNum)")
                                .foregroundStyle(MobileColors.accent)
                            if let aired = DateFormatting.formatMediumDate(episode.premiereDate) {
                                Text("• \(aired)")
                                    .foregroundStyle(MobileColors.textTertiary)
                            }
                        }
                        .font(MobileTypography.captionSmall)
                    }
                    Text(episode.name)
                        .font(MobileTypography.titleSmall)
                        .foregroundStyle(MobileColors.textPrimary)
                        .lineLimit(2)
                    if let runtime = episode.runTimeTicks {
                        Text(Self.formatRuntime(runtime))
                            .font(MobileTypography.captionSmall)
                            .foregroundStyle(MobileColors.textTertiary)
                    }
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Long-press: the episode download menu (#744) and the usual
            // item actions. The menu acts on the active server.
            if serverID == nil { ItemContextMenu(item: episode) }
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .topTrailing) {
            LazyImage(request: thumbnailRequest) { state in
                if let image = state.image {
                    image
                        .resizable().scaledToFill()
                } else {
                    Rectangle().fill(MobileColors.cardBackground)
                }
            }
            .frame(width: 120, height: 68)

            // Watched checkmark (tvOS parity)
            if episode.userData?.played == true {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white, Color(red: 0.29, green: 0.73, blue: 0.47))
                    .padding(3)
            }

            // Progress bar (tvOS parity)
            if episode.progressPercent > 0 {
                VStack {
                    Spacer()
                    GeometryReader { geo in
                        Rectangle()
                            .fill(MobileColors.accent)
                            .frame(width: geo.size.width * episode.progressPercent, height: 3)
                    }
                    .frame(height: 3)
                }
            }
        }
    }

    private var thumbnailRequest: ImageRequest? {
        let url: URL?
        if !NetworkMonitor.shared.isOnline {
            url = OfflineImageHelper.thumbnailURL(for: episode.id, serverID: serverID)
        } else {
            let serverURL = serverID.flatMap { id in SessionManager.shared.servers.first { $0.id == id }?.url }
                ?? (serverID == nil ? SessionManager.shared.serverURL : nil)
            url = serverURL.flatMap {
                JellyfinClient.shared.syncImageURL(
                    itemId: episode.id,
                    imageType: "Primary",
                    maxWidth: ImageSizing.pixelWidth(points: 120),
                    tag: episode.imageTag(for: "Primary", itemId: episode.id),
                    serverURL: $0
                )
            }
        }
        return url.map { SashimiImagePipeline.request(url: $0, serverID: serverID) }
    }

    private static func formatRuntime(_ ticks: Int64) -> String {
        let seconds = ticks / 10_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes) min"
    }
}

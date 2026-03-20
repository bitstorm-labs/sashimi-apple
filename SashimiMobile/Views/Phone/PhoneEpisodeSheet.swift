import SwiftUI
import NukeUI

struct PhoneEpisodeSheet: View {
    let episode: BaseItemDto
    var libraryName: String?
    @State private var playingItem: BaseItemDto?
    @Environment(\.dismiss) private var dismiss

    private var imageURL: URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        return URL(string: "\(serverURL)/Items/\(episode.id)/Images/Primary?maxWidth=800")
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
              ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: MobileSpacing.md) {
                    LazyImage(url: imageURL) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(MobileColors.cardBackground)
                        }
                    }
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipped()

                    VStack(alignment: .leading, spacing: MobileSpacing.sm) {
                        if let season = episode.parentIndexNumber, let episodeNum = episode.indexNumber {
                            Text("S\(season):E\(episodeNum)")
                                .font(MobileTypography.caption)
                                .foregroundStyle(MobileColors.accent)
                        }

                        Text(episode.name)
                            .font(MobileTypography.headline)
                            .foregroundStyle(MobileColors.textPrimary)

                        if let runtime = episode.runTimeTicks {
                            Text(formatRuntime(runtime))
                                .font(MobileTypography.caption)
                                .foregroundStyle(MobileColors.textSecondary)
                        }

                        HStack(spacing: MobileSpacing.md) {
                            Button {
                                playingItem = episode
                            } label: {
                                Label(
                                    (episode.userData?.playbackPositionTicks ?? 0) > 0 ? "Resume" : "Play",
                                    systemImage: "play.fill"
                                )
                                .font(.system(size: 14, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)

                            if NetworkMonitor.shared.isConnected {
                                DownloadButton(item: episode, quality: nil)
                            }

                            Spacer()
                        }

                        if let overview = episode.overview, !overview.isEmpty {
                            Text(overview)
                                .font(MobileTypography.body)
                                .foregroundStyle(MobileColors.textSecondary)
                                .lineLimit(10)
                        }
                    }
                    .padding(.horizontal, MobileSpacing.md)
                }
                .frame(width: proxy.size.width)
              }
            }
            .background(MobileColors.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .fullScreenPlayer(item: $playingItem)
    }

    private func formatRuntime(_ ticks: Int64) -> String {
        let seconds = ticks / 10_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes) min"
    }
}

import SwiftUI
import SwiftData

struct OfflineSeriesView: View {
    let seriesName: String
    let episodes: [DownloadedItem]
    @State private var playingItem: BaseItemDto?
    @State private var selectedSeason: Int?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var seasons: [Int] {
        Array(Set(episodes.compactMap { $0.seasonNumber })).sorted()
    }

    private var filteredEpisodes: [DownloadedItem] {
        guard let season = selectedSeason else { return episodes }
        return episodes.filter { $0.seasonNumber == season }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Backdrop from first episode's backdrop.jpg
                backdropSection

                VStack(alignment: .leading, spacing: MobileSpacing.md) {
                    // Title
                    Text(seriesName)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(MobileColors.textPrimary)

                    // Info
                    HStack(spacing: MobileSpacing.sm) {
                        if seasons.count > 0 {
                            Text(seasons.count == 1 ? "1 Season" : "\(seasons.count) Seasons")
                        }
                        Text("\u{2022}")
                        Text("\(episodes.count) Episodes")
                    }
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textSecondary)

                    // Season picker
                    if seasons.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: MobileSpacing.sm) {
                                ForEach(seasons, id: \.self) { season in
                                    Button {
                                        withAnimation {
                                            selectedSeason = selectedSeason == season ? nil : season
                                        }
                                    } label: {
                                        Text("Season \(season)")
                                            .font(.system(size: 14, weight: selectedSeason == season ? .bold : .medium))
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(selectedSeason == season ? MobileColors.accent : MobileColors.cardBackground)
                                            .foregroundStyle(selectedSeason == season ? .black : .white)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                    }

                    // Episodes header
                    Text("Episodes")
                        .font(MobileTypography.headline)
                        .foregroundStyle(MobileColors.textPrimary)

                    // Episode list
                    LazyVStack(spacing: MobileSpacing.sm) {
                        ForEach(filteredEpisodes, id: \.itemId) { episode in
                            Button { playingItem = episode.asBaseItemDto } label: {
                                episodeRow(episode)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer().frame(height: 40)
                }
                .padding(.horizontal, MobileSpacing.md)
                .padding(.top, MobileSpacing.sm)
            }
        }
        .background(MobileColors.background)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenPlayer(item: $playingItem)
        .onAppear {
            if seasons.count == 1 {
                selectedSeason = seasons.first
            }
        }
    }

    // MARK: - Backdrop

    private var backdropSection: some View {
        ZStack(alignment: .bottom) {
            // Try backdrop from first episode
            if let firstEp = episodes.first, let image = loadLocalImage(itemId: firstEp.itemId, fileNames: ["backdrop.jpg", "poster.jpg"]) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: sizeClass == .compact ? 180 : 220)
                    .frame(maxWidth: .infinity)
                    .clipped()
            } else {
                Rectangle().fill(MobileColors.cardBackground)
                    .frame(height: sizeClass == .compact ? 180 : 220)
            }

            LinearGradient(
                colors: [.clear, MobileColors.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
        }
    }

    // MARK: - Episode Row

    private func episodeRow(_ episode: DownloadedItem) -> some View {
        HStack(spacing: MobileSpacing.sm) {
            // Thumbnail — use UIImage for reliable local loading
            if let image = loadLocalImage(itemId: episode.itemId, fileNames: ["poster.jpg"]) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))
                    .overlay {
                        if episode.lastPlaybackPositionTicks > 0, let total = episode.runTimeTicks, total > 0 {
                            VStack {
                                Spacer()
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Rectangle().fill(MobileColors.progressBackground)
                                        Rectangle()
                                            .fill(MobileColors.accent)
                                            .frame(width: geo.size.width * CGFloat(episode.lastPlaybackPositionTicks) / CGFloat(total))
                                    }
                                }
                                .frame(height: 3)
                            }
                        }
                    }
            } else {
                Rectangle()
                    .fill(MobileColors.cardBackground)
                    .frame(width: 120, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(MobileColors.textTertiary)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                if let season = episode.seasonNumber, let ep = episode.episodeNumber {
                    Text("S\(season):E\(ep)")
                        .font(MobileTypography.captionSmall)
                        .foregroundStyle(MobileColors.accent)
                }
                Text(episode.name)
                    .font(MobileTypography.titleSmall)
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(2)
                if let runtime = episode.runTimeTicks {
                    let minutes = runtime / 10_000_000 / 60
                    Text("\(minutes) min")
                        .font(MobileTypography.captionSmall)
                        .foregroundStyle(MobileColors.textTertiary)
                }
            }

            Spacer()

            Image(systemName: "play.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(MobileColors.accent)
        }
    }

    // MARK: - Local Image Loading (UIImage — reliable for file:// URLs)

    private func loadLocalImage(itemId: String, fileNames: [String]) -> UIImage? {
        let dir = DownloadFileManager.itemDirectory(for: itemId)
        for fileName in fileNames {
            let path = dir.appendingPathComponent(fileName).path
            if let image = UIImage(contentsOfFile: path) {
                return image
            }
        }
        return nil
    }
}

import SwiftUI
import NukeUI

struct MobileDetailView: View {
    let item: BaseItemDto

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileSpacing.lg) {
                // Hero section
                heroSection

                // Info section
                VStack(alignment: .leading, spacing: MobileSpacing.md) {
                    // Title and metadata
                    titleSection

                    // Action buttons
                    actionButtons

                    // Overview
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(MobileTypography.body)
                            .foregroundStyle(MobileColors.textSecondary)
                    }

                    // Additional metadata
                    metadataSection
                }
                .padding(.horizontal, MobileSpacing.md)
            }
        }
        .navigationTitle(item.name ?? "Details")
        .navigationBarTitleDisplayMode(.inline)
        .background(MobileColors.background)
    }

    private var heroSection: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Backdrop image
                if let backdropURL = backdropImageURL {
                    LazyImage(url: backdropURL) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle()
                                .fill(MobileColors.cardBackground)
                        }
                    }
                    .frame(width: geometry.size.width, height: 300)
                    .clipped()
                } else {
                    Rectangle()
                        .fill(MobileColors.cardBackground)
                }

                // Gradient overlay
                LinearGradient(
                    colors: [.clear, MobileColors.background],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .frame(height: 300)
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.xs) {
            Text(item.name ?? "Unknown")
                .font(MobileTypography.displayMedium)
                .foregroundStyle(MobileColors.textPrimary)

            HStack(spacing: MobileSpacing.sm) {
                if let year = item.productionYear {
                    Text(String(year))
                }

                if let runtime = item.runTimeTicks {
                    let minutes = runtime / 600_000_000
                    Text("\(minutes) min")
                }

                if let rating = item.officialRating {
                    Text(rating)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MobileColors.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .font(MobileTypography.body)
            .foregroundStyle(MobileColors.textSecondary)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: MobileSpacing.md) {
            // Play button
            Button {
                // Will be implemented with player
            } label: {
                Label(item.userData?.playbackPositionTicks ?? 0 > 0 ? "Resume" : "Play", systemImage: "play.fill")
                    .font(MobileTypography.title)
            }
            .buttonStyle(.borderedProminent)

            // More options
            Menu {
                if item.userData?.played == true {
                    Button {
                        Task { try? await JellyfinClient.shared.markUnplayed(itemId: item.id) }
                    } label: {
                        Label("Mark as Unwatched", systemImage: "eye.slash")
                    }
                } else {
                    Button {
                        Task { try? await JellyfinClient.shared.markPlayed(itemId: item.id) }
                    } label: {
                        Label("Mark as Watched", systemImage: "eye")
                    }
                }

                if item.userData?.isFavorite == true {
                    Button {
                        Task { try? await JellyfinClient.shared.removeFavorite(itemId: item.id) }
                    } label: {
                        Label("Remove from Favorites", systemImage: "heart.slash")
                    }
                } else {
                    Button {
                        Task { try? await JellyfinClient.shared.markFavorite(itemId: item.id) }
                    } label: {
                        Label("Add to Favorites", systemImage: "heart")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(MobileTypography.title)
            }
            .buttonStyle(.bordered)

            Spacer()
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            if let genres = item.genres, !genres.isEmpty {
                metadataRow(label: "Genres", value: genres.joined(separator: ", "))
            }

            if let communityRating = item.communityRating {
                metadataRow(label: "Rating", value: String(format: "%.1f", communityRating))
            }
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(MobileTypography.body)
                .foregroundStyle(MobileColors.textTertiary)
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(MobileTypography.body)
                .foregroundStyle(MobileColors.textSecondary)
        }
    }

    private var backdropImageURL: URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }

        let imageId: String
        if item.backdropImageTags?.isEmpty == false {
            imageId = item.id
        } else if item.parentBackdropImageTags?.isEmpty == false {
            // For episodes, use series ID for backdrop
            imageId = item.seriesId ?? item.id
        } else {
            return nil
        }

        return URL(string: "\(serverURL)/Items/\(imageId)/Images/Backdrop?maxWidth=1280")
    }
}

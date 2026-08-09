import SwiftUI
import NukeUI

struct PersonDetailView: View {
    let person: PersonInfo
    let excludingItemID: String?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = PersonFilmographyViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileSpacing.lg) {
                headerSection
                filmographySection
            }
            .padding(.horizontal, MobileSpacing.md)
            .padding(.vertical, MobileSpacing.md)
        }
        .background(MobileColors.background)
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .accessibilityHint("Return to the previous screen")
            }
        }
        .task {
            await loadFilmography()
        }
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: MobileSpacing.md) {
            personImage

            VStack(alignment: .leading, spacing: MobileSpacing.xs) {
                Text(person.name)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(MobileColors.textPrimary)

                Text(person.displayRole ?? "Cast & Crew")
                    .font(MobileTypography.body)
                    .foregroundStyle(MobileColors.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var personImage: some View {
        if person.primaryImageTag != nil,
           let imageURL = JellyfinClient.shared.personImageURL(personId: person.id, maxWidth: 220) {
            LazyImage(url: imageURL) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    personPlaceholder
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(Circle())
        } else {
            personPlaceholder
        }
    }

    private var personPlaceholder: some View {
        Circle()
            .fill(MobileColors.cardBackground)
            .frame(width: 96, height: 96)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(MobileColors.textTertiary)
            }
    }

    @ViewBuilder
    private var filmographySection: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text("Filmography on This Server")
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)

            switch viewModel.state {
            case .idle, .loading:
                ProgressView("Loading filmography...")
                    .frame(maxWidth: .infinity, minHeight: 240)
            case .unavailable:
                ContentUnavailableView {
                    Label("Filmography Unavailable", systemImage: "wifi.slash")
                } description: {
                    Text("Connect to your Jellyfin server to view this person's other media.")
                } actions: {
                    Button("Retry") {
                        Task { await loadFilmography() }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Filmography", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        Task { await loadFilmography() }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            case .loaded:
                if viewModel.items.isEmpty {
                    ContentUnavailableView(
                        "No Other Movies or Shows",
                        systemImage: "film.stack",
                        description: Text("No other accessible media was found for this person.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    LazyVStack(spacing: MobileSpacing.xs) {
                        ForEach(viewModel.items) { item in
                            NavigationLink {
                                AdaptiveDetailView(item: item, libraryName: libraryName(for: item))
                            } label: {
                                PersonFilmographyRow(item: item)
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(item.displayTitle)
                            .accessibilityHint("Open title details")
                        }
                    }
                }
            }
        }
    }

    private func loadFilmography() async {
        await viewModel.load(
            personID: person.id,
            excludingItemID: excludingItemID,
            isOffline: !NetworkMonitor.shared.isConnected
        )
    }

    private func isYouTube(_ item: BaseItemDto) -> Bool {
        item.path?.localizedCaseInsensitiveContains("youtube") == true
    }

    private func libraryName(for item: BaseItemDto) -> String? {
        isYouTube(item) ? "YouTube" : nil
    }
}

private struct PersonFilmographyRow: View {
    let item: BaseItemDto

    @AppStorage("showQualityBadges") private var showQualityBadges = true
    @AppStorage("showReviewRatings") private var showReviewRatings = true
    @AppStorage("useEpisodeRatings") private var useEpisodeRatings = false

    var body: some View {
        HStack(spacing: MobileSpacing.sm) {
            VStack(alignment: .leading, spacing: MobileSpacing.xxs) {
                Text(item.displayTitle)
                    .font(MobileTypography.title)
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(2)

                HStack(spacing: MobileSpacing.xs) {
                    if let year = item.displayYear {
                        metadataText(String(year))
                    }
                    if let type = item.type {
                        metadataText(type == .series ? "Show" : type.rawValue)
                    }
                    if let officialRating = item.officialRating {
                        metadataText(officialRating)
                    }
                    if showReviewRatings,
                       let rating = item.coverReviewRating(useEpisodeRatings: useEpisodeRatings) {
                        ReviewRatingBadge(
                            rating: rating,
                            fontSize: 11,
                            logoHeight: 11,
                            horizontalPadding: 6,
                            verticalPadding: 3,
                            cornerRadius: 5
                        )
                    }
                    if showQualityBadges, let quality = item.qualityBadge {
                        QualityBadge(
                            label: quality,
                            fontSize: 11,
                            horizontalPadding: 6,
                            verticalPadding: 3,
                            cornerRadius: 5
                        )
                    }
                }
            }

            Spacer(minLength: MobileSpacing.xs)

            HStack {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MobileColors.textTertiary)
            }
        }
        .padding(.horizontal, MobileSpacing.sm)
        .padding(.vertical, MobileSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: MobileSizing.minTappableSize, alignment: .leading)
        .background(MobileColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.medium))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Open title details")
    }

    private func metadataText(_ value: String) -> some View {
        Text(value)
            .font(MobileTypography.caption)
            .foregroundStyle(MobileColors.textSecondary)
    }

    private var accessibilityDescription: String {
        var parts = [item.displayTitle]
        if let year = item.displayYear {
            parts.append(String(year))
        }
        if let rating = item.coverReviewRating(useEpisodeRatings: useEpisodeRatings) {
            parts.append("rating \(String(format: "%.1f", rating))")
        }
        if let quality = item.qualityBadge {
            parts.append(quality)
        }
        return parts.joined(separator: ", ")
    }
}

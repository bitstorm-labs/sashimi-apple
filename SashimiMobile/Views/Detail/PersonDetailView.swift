import SwiftUI
import NukeUI

struct PersonDetailView: View {
    let person: PersonInfo
    let excludingItemID: String?

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
            Text("Other Movies & Shows")
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
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: MobileSizing.posterWidth), spacing: MobileSpacing.md)],
                        spacing: MobileSpacing.md
                    ) {
                        ForEach(viewModel.items) { item in
                            NavigationLink {
                                AdaptiveDetailView(item: item, libraryName: libraryName(for: item))
                            } label: {
                                MobileRecentlyAddedCard(
                                    item: item,
                                    width: MobileSizing.posterWidth,
                                    libraryName: libraryName(for: item),
                                    isCircular: isYouTube(item) && item.type == .series,
                                    isLandscape: false,
                                    badgeCount: nil
                                )
                            }
                            .buttonStyle(.plain)
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

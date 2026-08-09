import SwiftUI
import NukeUI

struct PersonDetailView: View {
    let person: PersonInfo
    let excludingItemID: String?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = PersonFilmographyViewModel()
    @State private var selectedItem: BaseItemDto?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                backButton
                headerSection
                filmographySection
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 40)
        }
        .background(SashimiTheme.background.ignoresSafeArea())
        .fullScreenCover(item: $selectedItem) { item in
            MediaDetailView(item: item, forceYouTubeStyle: isYouTubeStyle(item))
        }
        .task {
            await loadFilmography()
        }
        .onExitCommand {
            dismiss()
        }
    }

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Label("Back", systemImage: "chevron.left")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Return to the previous screen")
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 28) {
            personImage

            VStack(alignment: .leading, spacing: 10) {
                Text(person.name)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(SashimiTheme.textPrimary)

                Text(person.displayRole ?? "Cast & Crew")
                    .font(.title3)
                    .foregroundStyle(SashimiTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var personImage: some View {
        if person.primaryImageTag != nil,
           let imageURL = JellyfinClient.shared.personImageURL(personId: person.id, maxWidth: 320) {
            LazyImage(url: imageURL) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    personPlaceholder
                }
            }
            .pipeline(SashimiImagePipeline.shared)
            .frame(width: 160, height: 160)
            .clipShape(Circle())
        } else {
            personPlaceholder
        }
    }

    private var personPlaceholder: some View {
        Circle()
            .fill(SashimiTheme.cardBackground)
            .frame(width: 160, height: 160)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(SashimiTheme.textTertiary)
            }
    }

    @ViewBuilder
    private var filmographySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Filmography on This Server")
                .font(.title2.weight(.semibold))
                .foregroundStyle(SashimiTheme.textPrimary)

            switch viewModel.state {
            case .idle, .loading:
                LoadingStateView(message: "Loading filmography...")
                    .frame(minHeight: 320)
            case .unavailable:
                OfflineStateView {
                    Task { await loadFilmography() }
                }
                .frame(minHeight: 320)
            case .failed(let message):
                ErrorStateView(title: "Couldn't Load Filmography", message: message) {
                    Task { await loadFilmography() }
                }
                .frame(minHeight: 320)
            case .loaded:
                if viewModel.items.isEmpty {
                    EmptyStateView(
                        icon: "film.stack",
                        title: "No Other Movies or Shows",
                        message: "No other accessible media was found for this person."
                    )
                    .frame(minHeight: 320)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220), spacing: 28)],
                        spacing: 36
                    ) {
                        ForEach(viewModel.items) { item in
                            MediaPosterButton(
                                item: item,
                                libraryName: libraryName(for: item),
                                isCircular: isYouTube(item) && item.type == .series
                            ) {
                                selectedItem = item
                            }
                        }
                    }
                    .focusSection()
                }
            }
        }
    }

    private func loadFilmography() async {
        await viewModel.load(personID: person.id, excludingItemID: excludingItemID)
    }

    private func isYouTubeStyle(_ item: BaseItemDto) -> Bool {
        item.path?.localizedCaseInsensitiveContains("youtube") == true
    }

    private func isYouTube(_ item: BaseItemDto) -> Bool {
        isYouTubeStyle(item)
    }

    private func libraryName(for item: BaseItemDto) -> String? {
        isYouTube(item) ? "YouTube" : nil
    }
}

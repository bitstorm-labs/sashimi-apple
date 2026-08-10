import SwiftUI
import NukeUI

struct PersonDetailView: View {
    let person: PersonInfo
    let excludingItemID: String?
    let excludingTitleKey: String?
    let originatingServerID: String?
    let onSelectSource: (ServerMediaResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = PersonFilmographyViewModel()
    @State private var selectedGroup: ServerMediaResultGroup?

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
        .sheet(item: $selectedGroup) { group in
            ServerMediaSourcePickerView(group: group) { source in
                selectedGroup = nil
                onSelectSource(source)
            }
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
            Text("Filmography Across Servers")
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
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.items) { group in
                            PersonFilmographyRow(group: group) {
                                select(group)
                            }
                        }
                    }
                    .focusSection()
                }
            }
        }
    }

    private func loadFilmography() async {
        let serverID = originatingServerID ?? SessionManager.shared.activeServerId
        await viewModel.load(
            person: person,
            originatingServerID: serverID,
            excludingItemID: excludingItemID,
            excludingTitleKey: excludingTitleKey,
            isOffline: !NetworkMonitor.shared.isConnected
        )
    }

    private func select(_ group: ServerMediaResultGroup) {
        if group.sources.count == 1, let source = group.sources.first {
            onSelectSource(source)
        } else {
            selectedGroup = group
        }
    }
}

private struct PersonFilmographyRow: View {
    let group: ServerMediaResultGroup
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool
    @AppStorage("showQualityBadges") private var showQualityBadges = true
    @AppStorage("showReviewRatings") private var showReviewRatings = true
    @AppStorage("useEpisodeRatings") private var useEpisodeRatings = false

    private var item: BaseItemDto { group.primary.item }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.displayTitle)
                        .font(Typography.title)
                        .foregroundStyle(isFocused ? .black : SashimiTheme.textPrimary)
                        .lineLimit(2)

                    HStack(spacing: 10) {
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
                                fontSize: 16,
                                logoHeight: 15,
                                horizontalPadding: 8,
                                verticalPadding: 4,
                                cornerRadius: 6
                            )
                        }
                        if showQualityBadges, let quality = item.qualityBadge {
                            QualityBadge(
                                label: quality,
                                fontSize: 16,
                                horizontalPadding: 8,
                                verticalPadding: 4,
                                cornerRadius: 6
                            )
                        }
                    }

                    ServerSourcePillsView(sources: group.sources)
                }

                Spacer(minLength: 16)

                HStack {
                    Image(systemName: "chevron.right")
                        .font(.headline)
                        .foregroundStyle(isFocused ? .black : SashimiTheme.textTertiary)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .background(isFocused ? Color.white : SashimiTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 3)
            }
            .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 12)
            .scaleEffect(isFocused ? 1.02 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Double-tap to view details")
    }

    private func metadataText(_ value: String) -> some View {
        Text(value)
            .font(Typography.bodySmall)
            .foregroundStyle(isFocused ? .black.opacity(0.7) : SashimiTheme.textSecondary)
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

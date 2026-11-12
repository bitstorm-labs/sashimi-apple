import NukeUI
import SwiftUI

/// A title the server doesn't have, on iPhone, iPad and Mac (design §3): the
/// Spotlight's portrait backdrop (#894), details from the server's metadata providers, Add to
/// Watchlist / ✓ On Watchlist, and Request (or Sign in to Requests). Once the
/// server has the title, the normal library page with Play takes over.
struct MobileWatchlistTitleView: View {
    @StateObject private var model: WatchlistTitleModel
    @State private var seasonPlan: SeerrSeasonPlan?
    @State private var message: String?

    init(seed: WatchlistTitleSeed) {
        _model = StateObject(wrappedValue: WatchlistTitleModel(seed: seed))
    }

    var body: some View {
        if let item = model.libraryItem {
            AdaptiveDetailView(item: item, libraryName: item.libraryName)
        } else {
            page
                .task { await model.load() }
                .listMessage($message)
                .sheet(item: $seasonPlan) { plan in
                    MobileSeerrSeasonSheet(title: model.title, plan: plan) { chosen in
                        seasonPlan = nil
                        Task { await model.seerrModel?.requestSeasons(chosen) }
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileSpacing.sm) {
                hero
                VStack(alignment: .leading, spacing: MobileSpacing.sm) {
                    Text(WatchlistV2Text.notOnYourServer)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                    if let overview = model.overview {
                        Text(overview)
                            .font(MobileTypography.body)
                            .foregroundStyle(MobileColors.textSecondary)
                            .frame(maxWidth: 640, alignment: .leading)
                    } else if model.isLoading {
                        ProgressView()
                    }
                    actions
                    if let error = model.errorMessage ?? model.seerrModel?.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(MobileTypography.caption)
                            .foregroundStyle(MobileColors.warning)
                    }
                    if let source = model.sourceLine {
                        Text(source)
                            .font(MobileTypography.caption)
                            .foregroundStyle(MobileColors.textTertiary)
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
            }
            .padding(.bottom, MobileSpacing.md)
        }
        .background(MobileColors.background)
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The Spotlight's portrait form (#894): the backdrop across the top,
    /// fading over its lower half into the page, the title on the faded part.
    /// No backdrop: the poster, soft and grey, as the Spotlight shows it.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                if let url = model.backdropURL {
                    LazyImage(url: url) { state in
                        if let image = state.image { image.resizable().scaledToFill() }
                    }
                } else if let poster = model.posterURL {
                    SeerrArtwork(url: poster, title: "", cornerRadius: 0)
                        .blur(radius: 30)
                        .grayscale(1)
                        .brightness(-0.3)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(3 / 2, contentMode: .fit)
            .frame(maxHeight: 340)
            .clipped()
            .spotlightFade(.portrait)

            HStack(alignment: .bottom, spacing: MobileSpacing.sm) {
                VStack(alignment: .leading, spacing: MobileSpacing.xxs) {
                    Text(model.title)
                        .font(MobileTypography.displayLarge)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(model.metaLine)
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textSecondary)
                    if let genres = model.genreLine {
                        Text(genres)
                            .font(MobileTypography.caption)
                            .foregroundStyle(MobileColors.textSecondary)
                    }
                }
            }
            .padding(.horizontal, MobileSpacing.md)
            .offset(y: 40)
        }
        .padding(.bottom, 40)
    }

    private var actions: some View {
        HStack(spacing: MobileSpacing.sm) {
            Button {
                Task { if !(await model.toggleWatchlist()) { message = WatchlistV2Text.couldntChange } }
            } label: {
                Label(model.isOnWatchlist ? WatchlistV2Text.onWatchlist : WatchlistV2Text.addTitle,
                      systemImage: model.isOnWatchlist ? "checkmark" : "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isOnWatchlist ? MobileColors.cardBackground : MobileColors.accent)
            .disabled(model.isToggling)

            switch model.requestButton {
            case .hidden:
                EmptyView()
            case .signIn:
                NavigationLink { MobileRequestsSettingsView() } label: {
                    Label(ListSpotlightText.signInToRequests, systemImage: "person.crop.circle")
                }
                .buttonStyle(.bordered)
            case .loading:
                ProgressView()
            case .request:
                Button { Task { await model.requestMovie() } } label: {
                    Label(ListSpotlightText.request, systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .disabled(model.seerrModel?.isSubmitting == true)
            case .chooseSeasons:
                Button { seasonPlan = model.seerrModel?.seasonPlan() } label: {
                    Label(ListSpotlightText.request, systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .disabled(model.seerrModel?.isSubmitting == true)
            case .status(let text):
                Label(text, systemImage: "clock")
                    .font(MobileTypography.caption.weight(.semibold))
                    .foregroundStyle(MobileColors.textSecondary)
            }
        }
        .font(.system(size: 15, weight: .semibold))
    }
}

/// ＋ Add on iPhone, iPad and Mac (design §2): one search, "On your server"
/// and "Not on server". ＋ adds a result ("✓ Added" once it's on the
/// Watchlist); tapping it opens its page.
struct MobileWatchlistSearchView: View {
    @StateObject private var model = WatchlistSearchModel()
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        List {
            switch model.phase {
            case .idle:
                Text(WatchlistV2Text.typeToSearch)
                    .foregroundStyle(MobileColors.textTertiary)
            case .searching:
                ProgressView().frame(maxWidth: .infinity)
            case .unavailable:
                Text(WatchlistV2Text.searchUnavailable).foregroundStyle(MobileColors.textTertiary)
            case .failed:
                Text(WatchlistV2Text.couldntSearch).foregroundStyle(MobileColors.textTertiary)
            case .results:
                section(WatchlistV2Text.onYourServer, model.onServer)
                section(WatchlistV2Text.notOnServer, model.notOnServer)
            }
        }
        .listStyle(.plain)
        .searchable(text: $model.text, placement: .navigationBarDrawer(displayMode: .always), prompt: WatchlistV2Text.searchPrompt)
        .onSubmit(of: .search) { model.searchNow() }
        .navigationTitle(WatchlistV2Text.addTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .listMessage($message)
    }

    private func section(_ title: String, _ hits: [WatchlistSearchHit]) -> some View {
        Section(title) {
            if hits.isEmpty {
                Text(WatchlistV2Text.noResults).foregroundStyle(MobileColors.textTertiary)
            }
            ForEach(hits) { hit in
                HStack(spacing: MobileSpacing.sm) {
                    NavigationLink {
                        if let itemId = hit.itemId {
                            MobileLibraryItemLoader(itemId: itemId)
                        } else {
                            MobileWatchlistTitleView(seed: hit.titleSeed)
                        }
                    } label: {
                        HStack(spacing: MobileSpacing.sm) {
                            poster(hit)
                                .frame(width: 40, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.title)
                                    .font(MobileTypography.body.weight(.semibold))
                                    .foregroundStyle(MobileColors.textPrimary)
                                    .lineLimit(1)
                                Text([hit.year.map(String.init), hit.kind == .movie ? "Movie" : "Show"].compactMap { $0 }
                                        .joined(separator: " · "))
                                    .font(MobileTypography.caption)
                                    .foregroundStyle(MobileColors.textSecondary)
                            }
                        }
                    }
                    Button {
                        Task { if !(await model.add(hit)) { message = WatchlistText.couldntAdd } }
                    } label: {
                        if model.isAdded(hit) {
                            Label(WatchlistV2Text.added, systemImage: "checkmark")
                        } else {
                            Label(WatchlistV2Text.add, systemImage: "plus")
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.bordered)
                    .tint(model.isAdded(hit) ? MobileColors.syncedText : MobileColors.accent)
                    .disabled(model.isAdded(hit) || model.isAdding(hit))
                }
            }
        }
    }

    @ViewBuilder
    private func poster(_ hit: WatchlistSearchHit) -> some View {
        if let itemId = hit.itemId {
            LazyImage(url: JellyfinClient.shared.syncImageURL(itemId: itemId, imageType: "Primary", maxWidth: 120)) { state in
                if let image = state.image { image.resizable().scaledToFill() } else { MobileColors.cardBackground }
            }
            .pipeline(SashimiImagePipeline.shared)
        } else {
            SeerrArtwork(url: hit.posterURL, title: "", cornerRadius: 0)
        }
    }
}

/// A library item's page, fetched by id (a search result carries only the id).
private struct MobileLibraryItemLoader: View {
    let itemId: String
    @State private var item: BaseItemDto?

    var body: some View {
        Group {
            if let item {
                AdaptiveDetailView(item: item, libraryName: item.libraryName)
            } else {
                ProgressView()
            }
        }
        .task { item = try? await JellyfinClient.shared.getItem(itemId: itemId) }
    }
}

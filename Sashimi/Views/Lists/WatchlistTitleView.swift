import NukeUI
import SwiftUI

/// A title the server doesn't have, on Apple TV (design §3): the Spotlight
/// backdrop (#894), details from the server's metadata providers, Add to Watchlist / ✓ On
/// Watchlist, and Request (or Sign in to Requests). Once the server has the
/// title, the normal library page with Play takes over.
struct WatchlistTitleView: View {
    @StateObject private var model: WatchlistTitleModel
    @State private var seasonPlan: SeerrSeasonPlan?
    @State private var signingIn = false

    init(seed: WatchlistTitleSeed) {
        _model = StateObject(wrappedValue: WatchlistTitleModel(seed: seed))
    }

    var body: some View {
        if let item = model.libraryItem {
            MediaDetailView(item: item)
        } else {
            page
                .toastOverlay()
                .task { await model.load() }
                .fullScreenCover(isPresented: $signingIn) { RequestsSignInCover() }
                .sheet(item: $seasonPlan) { plan in
                    SeerrSeasonPickerView(title: model.title, plan: plan) { chosen in
                        seasonPlan = nil
                        Task { await model.seerrModel?.requestSeasons(chosen) }
                    } onCancel: {
                        seasonPlan = nil
                    }
                }
        }
    }

    private var page: some View {
        ZStack(alignment: .topLeading) {
            SashimiTheme.background.ignoresSafeArea()
            backdrop
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(model.title)
                        .font(Typography.displayMedium)
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .lineLimit(2)
                    Text(model.metaLine)
                        .font(Typography.bodySmall)
                        .foregroundStyle(SashimiTheme.textSecondary)
                    if let genres = model.genreLine {
                        Text(genres)
                            .font(Typography.bodySmall)
                            .foregroundStyle(SashimiTheme.textSecondary)
                    }
                    SeerrStatusTag(label: WatchlistV2Text.notOnYourServer, color: .white, fontSize: 18, onArtwork: true)
                    if let overview = model.overview {
                        Text(overview)
                            .font(Typography.bodySmall)
                            .foregroundStyle(SashimiTheme.textSecondary)
                            .lineLimit(5)
                            .frame(maxWidth: 900, alignment: .leading)
                    } else if model.isLoading {
                        ProgressView().tint(SashimiTheme.accent)
                    }
                    actions
                        .padding(.top, 10)
                        .focusSection()
                    if let message = model.errorMessage ?? model.seerrModel?.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(Typography.caption)
                            .foregroundStyle(SashimiTheme.warning)
                    }
                    if let source = model.sourceLine {
                        Text(source)
                            .font(Typography.caption)
                            .foregroundStyle(SashimiTheme.textTertiary)
                    }
                }
                .frame(maxWidth: MediaDetailView.headerWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 80)
            .padding(.top, 100)
        }
    }

    /// The Watchlist Spotlight's backdrop (#894); the poster, soft and grey,
    /// when the provider has no backdrop, as the Spotlight shows it.
    private var backdrop: some View {
        SpotlightBackdrop { frame in
            if let url = model.backdropURL {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: frame.width, height: frame.height)
            } else if let poster = model.posterURL {
                SeerrArtwork(url: poster, title: "", cornerRadius: 0)
                    .frame(width: frame.width, height: frame.height)
                    .blur(radius: 30)
                    .grayscale(1)
                    .brightness(-0.3)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 24) {
            ActionButton(
                title: model.isOnWatchlist ? WatchlistV2Text.onWatchlist : WatchlistV2Text.addTitle,
                icon: model.isOnWatchlist ? "checkmark" : "plus",
                isPrimary: true,
                isActive: model.isOnWatchlist
            ) {
                Task {
                    if !(await model.toggleWatchlist()) { ToastManager.shared.show(WatchlistV2Text.couldntChange) }
                }
            }
            .disabled(model.isToggling)

            switch model.requestButton {
            case .hidden:
                EmptyView()
            case .signIn:
                ActionButton(title: ListSpotlightText.signInToRequests, icon: "person.crop.circle") { signingIn = true }
            case .loading:
                ProgressView().tint(SashimiTheme.accent)
            case .request:
                ActionButton(title: ListSpotlightText.request, icon: "arrow.down.circle") {
                    Task { await model.requestMovie() }
                }
                .disabled(model.seerrModel?.isSubmitting == true)
            case .chooseSeasons:
                ActionButton(title: ListSpotlightText.request, icon: "arrow.down.circle") {
                    seasonPlan = model.seerrModel?.seasonPlan()
                }
                .disabled(model.seerrModel?.isSubmitting == true)
            case .status(let text):
                Label(text, systemImage: "clock")
                    .font(Typography.bodySmall.weight(.semibold))
                    .foregroundStyle(SashimiTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// ＋ Add on Apple TV (design §2): one search, "On your server" and "Not on
/// server". Each result's ＋ adds it ("✓ Added" once it's on the Watchlist);
/// its title opens its page.
struct WatchlistSearchView: View {
    @StateObject private var model = WatchlistSearchModel()
    @State private var openItem: BaseItemDto?
    @State private var openSeed: WatchlistTitleSeed?

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    Label(WatchlistV2Text.addTitle, systemImage: "bookmark.fill")
                        .font(Typography.displayMedium)
                        .foregroundStyle(SashimiTheme.textPrimary)
                    TextField(WatchlistV2Text.searchPrompt, text: $model.text)
                        .font(Typography.body)
                        .frame(maxWidth: 900)
                        .onSubmit { model.searchNow() }
                    results
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 80)
                .padding(.vertical, 60)
            }
            .scrollClipDisabled()
        }
        .toastOverlay()
        .fullScreenCover(item: $openItem) { item in MediaDetailView(item: item) }
        .fullScreenCover(item: $openSeed) { seed in WatchlistTitleView(seed: seed) }
    }

    @ViewBuilder
    private var results: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .searching:
            ProgressView().tint(SashimiTheme.accent)
        case .unavailable:
            message(WatchlistV2Text.searchUnavailable)
        case .failed:
            message(WatchlistV2Text.couldntSearch)
        case .results:
            group(WatchlistV2Text.onYourServer, model.onServer)
            group(WatchlistV2Text.notOnServer, model.notOnServer)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Typography.bodySmall)
            .foregroundStyle(SashimiTheme.textTertiary)
    }

    private func group(_ title: String, _ hits: [WatchlistSearchHit]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.uppercased())
                .font(.system(size: 22, weight: .semibold))
                .kerning(1.5)
                .foregroundStyle(SashimiTheme.textSecondary)
            if hits.isEmpty {
                message(WatchlistV2Text.noResults)
            } else {
                ForEach(hits) { hit in
                    WatchlistSearchRow(hit: hit, isAdded: model.isAdded(hit), isAdding: model.isAdding(hit)) {
                        if let itemId = hit.itemId {
                            Task { openItem = try? await JellyfinClient.shared.getItem(itemId: itemId) }
                        } else {
                            openSeed = hit.titleSeed
                        }
                    } onAdd: {
                        Task {
                            if !(await model.add(hit)) { ToastManager.shared.show(WatchlistText.couldntAdd) }
                        }
                    }
                }
            }
        }
        .focusSection()
    }
}

/// One search result: poster, title, year and kind (opens its page), then ＋.
private struct WatchlistSearchRow: View {
    let hit: WatchlistSearchHit
    let isAdded: Bool
    let isAdding: Bool
    let onOpen: () -> Void
    let onAdd: () -> Void

    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 30) {
            Button(action: onOpen) {
                HStack(spacing: 24) {
                    poster
                        .frame(width: 80, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(hit.title)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(SashimiTheme.textPrimary)
                            .lineLimit(1)
                        Text([hit.year.map(String.init), hit.kind == .movie ? "Movie" : "Show"].compactMap { $0 }
                                .joined(separator: " · "))
                            .font(.system(size: 22))
                            .foregroundStyle(SashimiTheme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(width: 1100, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(titleFocused ? SashimiTheme.cardBackground : .clear))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(titleFocused ? SashimiTheme.focus : .clear, lineWidth: 3))
            }
            .buttonStyle(PlainNoHighlightButtonStyle())
            .focused($titleFocused)

            ActionButton(title: isAdded ? WatchlistV2Text.added : WatchlistV2Text.add,
                         icon: isAdded ? "checkmark" : "plus", isActive: isAdded, action: onAdd)
                .disabled(isAdded || isAdding)
        }
    }

    @ViewBuilder
    private var poster: some View {
        if let itemId = hit.itemId {
            AsyncItemImage(itemId: itemId, imageType: "Primary", maxWidth: 160, contentMode: .fill)
        } else {
            SeerrArtwork(url: hit.posterURL, title: hit.title, cornerRadius: 0)
        }
    }
}

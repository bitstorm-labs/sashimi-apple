import NukeUI
import SwiftUI

/// The request page on iPhone and iPad (mockup F): backdrop, title, Request
/// (a movie in one tap, a show through the season sheet), trailer, overview
/// and cast. Once the title is on the server it's the library page.
struct MobileSeerrDetailView: View {
    @StateObject private var model: SeerrDetailModel
    @State private var seasonPlan: SeerrSeasonPlan?
    @State private var addingToList = false
    @ObservedObject private var watchlist = WatchlistStore.shared
    @Environment(\.openURL) private var openURL
    private let opensSeasonPicker: Bool

    init(target: SeerrTarget, opensSeasonPicker: Bool = false) {
        _model = StateObject(wrappedValue: SeerrDetailModel(target: target))
        self.opensSeasonPicker = opensSeasonPicker
    }

    var body: some View {
        if let item = model.libraryItem, !opensSeasonPicker {
            AdaptiveDetailView(item: item, libraryName: item.libraryName)
        } else {
            page
                .task { await loadOnce() }
                .task { await watchlist.refresh() }
                .sheet(isPresented: $addingToList) {
                    MobileAddToListSheet(seerrTarget: model.target, year: model.details?.year)
                }
                .sheet(item: $seasonPlan) { plan in
                    MobileSeerrSeasonSheet(title: model.details?.title ?? model.target.title, plan: plan) { chosen in
                        seasonPlan = nil
                        Task { await model.requestSeasons(chosen) }
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
        }
    }

    private func loadOnce() async {
        guard model.details == nil else { return }
        await model.load()
        if opensSeasonPicker, model.action == .chooseSeasons {
            seasonPlan = model.seasonPlan()
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileSpacing.md) {
                backdrop
                VStack(alignment: .leading, spacing: MobileSpacing.md) {
                    titleBlock
                        // Over the backdrop's faded lower part (#894).
                        .padding(.top, -PhoneHeroBanner.contentOverlap)
                    actions
                    if let quota = model.quotaNote {
                        Text(quota)
                            .font(MobileTypography.caption)
                            .foregroundStyle(MobileColors.textTertiary)
                    }
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(MobileTypography.caption)
                            .foregroundStyle(MobileColors.warning)
                    }
                    if let overview = model.details?.overview, !overview.isEmpty {
                        Text(overview)
                            .font(MobileTypography.body)
                            .foregroundStyle(MobileColors.textSecondary)
                    }
                    if let cast = model.details?.credits?.cast, !cast.isEmpty {
                        castRow(Array(cast.prefix(15)))
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
                .frame(maxWidth: 820, alignment: .leading)
            }
            .padding(.bottom, 40)
        }
        .background(MobileColors.background)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The Spotlight's portrait form (#894): across the top, fading into the
    /// page over its lower half.
    private var backdrop: some View {
        ZStack(alignment: .bottom) {
            if let url = SeerrImages.backdrop(model.details?.backdropPath) {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .frame(height: PhoneHeroBanner.height)
        .frame(maxWidth: .infinity)
        .clipped()
        .spotlightFade(.portrait)
    }

    /// No poster beside the title (#894): the backdrop above stands for it.
    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: MobileSpacing.xs) {
                Text(model.details?.title ?? model.target.title)
                    .font(MobileTypography.displayMedium)
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(3)
                metadataRow
            }
        }
    }

    private var metadataRow: some View {
        WrappingHStack(spacing: 6) {
            if let details = model.details {
                let parts = [details.year.map(String.init), details.contentRating].compactMap { $0 }
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textSecondary)
                }
                if let status = details.seriesStatus {
                    SeriesStatusBadge(status: status, fontSize: 11)
                }
                switch model.badge {
                case .pending, .coming, .declined:
                    SeerrStatusTag(label: model.badge.label, color: model.badge.color, fontSize: 11)
                case .request, .available:
                    EmptyView()
                }
                let genres = details.genres.prefix(3).map(\.name)
                if !genres.isEmpty {
                    Text(genres.joined(separator: " • "))
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: MobileSpacing.sm) {
            switch model.action {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .request, .chooseSeasons:
                Button {
                    if model.action == .chooseSeasons {
                        seasonPlan = model.seasonPlan()
                    } else {
                        Task { await model.requestMovie() }
                    }
                } label: {
                    Label(model.isSubmitting ? "Requesting…" : "Request", systemImage: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .disabled(model.isSubmitting)
            case .status(let text):
                Label(text, systemImage: model.badge == .coming ? "arrow.down.circle" : "clock")
                    .font(MobileTypography.title)
                    .foregroundStyle(model.badge == .request ? MobileColors.textSecondary : model.badge.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(MobileTypography.body)
                    .foregroundStyle(MobileColors.warning)
            }

            if let key = model.details?.trailerKey, let url = SeerrTrailer.url(key: key) {
                Button {
                    openURL(url)
                } label: {
                    Label("Trailer", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

            // Only the Watchlist takes a title the server doesn't have.
            if watchlist.isAvailable {
                Button {
                    addingToList = true
                } label: {
                    Label(WatchlistText.addToList, systemImage: "text.badge.plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
    }

    private func castRow(_ cast: [SeerrCastMember]) -> some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text("Cast")
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: MobileSpacing.md) {
                    ForEach(cast) { member in
                        VStack(spacing: 4) {
                            SeerrArtwork(url: SeerrImages.profile(member.profilePath), title: "", cornerRadius: 36)
                                .frame(width: 72, height: 72)
                            Text(member.name)
                                .font(MobileTypography.captionSmall.weight(.semibold))
                                .foregroundStyle(MobileColors.textPrimary)
                            if let character = member.character, !character.isEmpty {
                                Text(character)
                                    .font(MobileTypography.captionSmall)
                                    .foregroundStyle(MobileColors.textTertiary)
                            }
                        }
                        .lineLimit(1)
                        .frame(width: 84)
                    }
                }
            }
        }
    }
}

/// The season picker as a bottom sheet (mockup F).
struct MobileSeerrSeasonSheet: View {
    let title: String
    @State var plan: SeerrSeasonPlan
    let onRequest: (SeerrSeasonPlan) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text("Request \(title)")
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)
                .padding(.top, MobileSpacing.lg)

            ScrollView {
                VStack(spacing: MobileSpacing.xs) {
                    if plan.partialRequestsEnabled, plan.missing.count > 1 {
                        row(title: "All missing seasons", detail: "\(plan.missing.count)",
                            isOn: plan.allMissingSelected, isPickable: true) {
                            plan.setAllMissing(!plan.allMissingSelected)
                        }
                    }
                    ForEach(plan.rows) { season in
                        row(title: season.title, detail: season.detail,
                            isOn: season.seasons.allSatisfy(plan.selected.contains),
                            isPickable: season.isPickable) {
                            season.seasons.forEach { plan.toggle($0) }
                        }
                    }
                }
            }

            Button {
                onRequest(plan)
            } label: {
                Text(plan.buttonTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(MobileColors.accent)
            .disabled(plan.requestSeasons.isEmpty)
            .padding(.bottom, MobileSpacing.sm)
        }
        .padding(.horizontal, MobileSpacing.md)
        .background(Color(red: 0.106, green: 0.106, blue: 0.13).ignoresSafeArea())
    }

    private func row(title: String, detail: String, isOn: Bool, isPickable: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: MobileSpacing.sm) {
                Image(systemName: isOn && isPickable ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(isOn && isPickable ? MobileColors.accent : MobileColors.textTertiary)
                Text(title)
                    .font(MobileTypography.body)
                    .foregroundStyle(MobileColors.textPrimary)
                Spacer()
                if detail == "On server" {
                    SeerrStatusTag(label: detail, color: SeerrBadge.available.color, fontSize: 11)
                } else {
                    Text(detail)
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textTertiary)
                }
            }
            .padding(.horizontal, MobileSpacing.sm)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: MobileCornerRadius.medium).fill(MobileColors.cardBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isPickable)
        .opacity(isPickable ? 1 : 0.45)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

extension View {
    /// "Request Missing Seasons" for a library show: checks Seerr when the
    /// show (with its TMDB id) is known, and presents the request page with
    /// the season sheet when the menu item sets `offer.presented`.
    func seerrMissingSeasons(_ offer: SeerrMissingSeasonsOffer, item: BaseItemDto) -> some View {
        self
            .task(id: "\(item.id)-\(item.tmdbId ?? 0)") {
                await offer.check(item)
            }
            .sheet(item: Binding(get: { offer.presented }, set: { offer.presented = $0 })) { target in
                NavigationStack {
                    MobileSeerrDetailView(target: target, opensSeasonPicker: true)
                }
            }
    }
}

/// The More-menu item that goes with `seerrMissingSeasons`.
struct SeerrMissingSeasonsMenuItem: View {
    @ObservedObject var offer: SeerrMissingSeasonsOffer

    var body: some View {
        if let target = offer.target {
            Button {
                offer.presented = target
            } label: {
                Label("Request Missing Seasons", systemImage: "tray.and.arrow.down")
            }
        }
    }
}

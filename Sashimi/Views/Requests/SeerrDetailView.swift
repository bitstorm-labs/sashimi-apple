import NukeUI
import SwiftUI

/// The page for a title that isn't on the server (mockup C): the same layout
/// as a library title, with Request where Play would be. Once the title has
/// arrived it turns into the normal library page.
struct SeerrDetailView: View {
    @StateObject private var model: SeerrDetailModel
    @State private var seasonPlan: SeerrSeasonPlan?
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    /// Opened from a library show's ⋯ menu: straight to the season picker,
    /// and the page stays the request page even though the show is in the
    /// library.
    private let opensSeasonPicker: Bool

    init(target: SeerrTarget, opensSeasonPicker: Bool = false) {
        _model = StateObject(wrappedValue: SeerrDetailModel(target: target))
        self.opensSeasonPicker = opensSeasonPicker
    }

    var body: some View {
        if let libraryItem = model.libraryItem, !opensSeasonPicker {
            MediaDetailView(item: libraryItem)
        } else {
            page
                .task { await loadOnce() }
                .sheet(item: $seasonPlan) { plan in
                    SeerrSeasonPickerView(title: model.details?.title ?? model.target.title, plan: plan) { chosen in
                        seasonPlan = nil
                        Task { await model.requestSeasons(chosen) }
                    } onCancel: {
                        seasonPlan = nil
                    }
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
            VStack(alignment: .leading, spacing: 50) {
                header
                if let cast = model.details?.credits?.cast, !cast.isEmpty {
                    castRow(Array(cast.prefix(15)))
                }
            }
            .padding(.top, 100)
            .padding(.bottom, 80)
        }
        .background { backdrop }
    }

    private var backdrop: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                SashimiTheme.background.ignoresSafeArea()
                if let url = SeerrImages.backdrop(model.details?.backdropPath) {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fit)
                        }
                    }
                    .frame(width: geometry.size.width * 0.55, alignment: .topTrailing)
                    .backdropFade()
                    .ignoresSafeArea()
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 50) {
            SeerrArtwork(
                url: SeerrImages.poster(model.details?.posterPath ?? model.target.posterPath),
                title: model.target.title,
                cornerRadius: 16,
                titleFont: .system(size: 26, weight: .bold)
            )
            .frame(width: 300, height: 450)

            VStack(alignment: .leading, spacing: 22) {
                Text(model.details?.title ?? model.target.title)
                    .font(Typography.displayMedium)
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .lineLimit(2)

                metadataRow

                if let overview = model.details?.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Typography.bodySmall)
                        .foregroundStyle(SashimiTheme.textSecondary)
                        .lineLimit(5)
                        .frame(maxWidth: 900, alignment: .leading)
                }

                actions
                    .padding(.top, 10)

                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.caption)
                        .foregroundStyle(SashimiTheme.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 80)
    }

    private var metadataRow: some View {
        HStack(spacing: 14) {
            let parts = metadataParts
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(Typography.bodySmall)
                    .foregroundStyle(SashimiTheme.textSecondary)
            }
            if let status = model.details?.seriesStatus {
                SeriesStatusBadge(status: status, fontSize: 18)
            }
            switch model.badge {
            case .pending, .coming, .declined:
                SeerrStatusTag(label: model.badge.label, color: model.badge.color, fontSize: 18)
            case .request, .available:
                EmptyView()
            }
        }
    }

    private var metadataParts: [String] {
        guard let details = model.details else { return [] }
        var parts: [String] = []
        if let year = details.year { parts.append(String(year)) }
        if let rating = details.contentRating { parts.append(rating) }
        let genres = details.genres.prefix(3).map(\.name)
        if !genres.isEmpty { parts.append(genres.joined(separator: " • ")) }
        return parts
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 20) {
            switch model.action {
            case .loading:
                ProgressView().tint(SashimiTheme.accent)
            case .request:
                ActionButton(title: model.isSubmitting ? "Requesting…" : "Request", icon: "plus", isPrimary: true) {
                    Task { await model.requestMovie() }
                }
                .disabled(model.isSubmitting)
            case .chooseSeasons:
                ActionButton(title: model.isSubmitting ? "Requesting…" : "Request", icon: "plus", isPrimary: true) {
                    seasonPlan = model.seasonPlan()
                }
                .disabled(model.isSubmitting)
            case .status(let text):
                statusLine(text)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.bodySmall)
                    .foregroundStyle(SashimiTheme.warning)
                ActionButton(title: "Close", icon: "xmark") { dismiss() }
            }

            if let key = model.details?.trailerKey, let url = SeerrTrailer.url(key: key) {
                ActionButton(title: "Trailer", icon: "play.fill") {
                    openURL(url) { accepted in
                        guard !accepted else { return }
                        Task { @MainActor in
                            ToastManager.shared.show("Install the YouTube app to watch trailers.", type: .info)
                        }
                    }
                }
            }
        }
    }

    private func statusLine(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: model.badge == .coming ? "arrow.down.circle" : "clock")
            Text(text)
        }
        .font(Typography.body.weight(.semibold))
        .foregroundStyle(model.badge == .request ? SashimiTheme.textSecondary : model.badge.color)
        .padding(.vertical, 10)
    }

    // MARK: Cast

    private func castRow(_ cast: [SeerrCastMember]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Cast")
                .font(Typography.headlineSmall)
                .foregroundStyle(SashimiTheme.textPrimary)
                .padding(.horizontal, 80)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 30) {
                    ForEach(cast) { member in
                        SeerrCastCard(member: member)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 20)
            }
            .focusSection()
        }
    }
}

/// A cast member from TMDB. Focusable so the row scrolls with the remote;
/// people pages are Jellyfin-only, so it does nothing when pressed.
private struct SeerrCastCard: View {
    let member: SeerrCastMember
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {} label: {
            VStack(spacing: 10) {
                SeerrArtwork(url: SeerrImages.profile(member.profilePath), title: "", cornerRadius: 80)
                    .frame(width: 160, height: 160)
                    .overlay(Circle().stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 4))
                Text(member.name)
                    .font(Typography.captionSmall.weight(.semibold))
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .lineLimit(1)
                if let character = member.character, !character.isEmpty {
                    Text(character)
                        .font(Typography.captionSmall)
                        .foregroundStyle(SashimiTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 180)
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityLabel(member.character.map { "\(member.name) as \($0)" } ?? member.name)
    }
}

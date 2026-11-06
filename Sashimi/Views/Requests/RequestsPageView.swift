import SwiftUI

/// The side menu's Requests page (#845), modelled on Seerr's website:
/// Discover (rows of titles to request, and a search) and Requests (the
/// request list, with approve and decline for those allowed). Only in the
/// rail while a Seerr account is connected; an expired sign-in shows the
/// sign-in screen here instead.
struct RequestsPageView: View {
    var onBackAtRoot: (() -> Void)?
    /// The rail's scope, so Right from the rail lands on the first tab.
    var focusNamespace: Namespace.ID?

    enum Section: String, CaseIterable, Identifiable {
        case discover
        case requests

        var id: String { rawValue }
        var title: String { self == .discover ? "Discover" : "Requests" }
        var icon: String { self == .discover ? "sparkles" : "tray.full" }
    }

    @ObservedObject private var session = SeerrSession.shared
    @State private var section: Section = .discover
    @StateObject private var discover = SeerrDiscoverModel()
    @StateObject private var search = SeerrSearchModel(includesAvailable: true)
    @State private var query = ""
    @State private var searchedQuery = ""
    @State private var openTarget: SeerrTarget?

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()
            if session.state == .expired {
                RequestsSettingsView()
            } else {
                page
            }
        }
        .fullScreenCover(item: $openTarget) { target in
            SeerrDetailView(target: target)
        }
        .onExitCommand {
            if !searchedQuery.isEmpty {
                clearSearch()
            } else {
                onBackAtRoot?()
            }
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                header
                    .padding(.horizontal, 60)
                switch section {
                case .discover:
                    discoverSection
                case .requests:
                    SeerrRequestListSection()
                }
            }
            .padding(.vertical, 50)
        }
        .scrollClipDisabled()
    }

    private var header: some View {
        HStack(spacing: 24) {
            Text("Requests")
                .font(Typography.displayMedium)
                .foregroundStyle(SashimiTheme.textPrimary)
                .padding(.trailing, 20)
            ForEach(Section.allCases) { item in
                GuideChip(label: item.title, systemImage: item.icon, selected: section == item) {
                    section = item
                }
                .requestsDefaultFocus(item == .discover, in: focusNamespace)
            }
            Spacer()
            Text("from \(session.applicationTitle)")
                .font(Typography.caption)
                .foregroundStyle(SashimiTheme.textTertiary)
        }
        .focusSection()
    }

    // MARK: Discover

    private var discoverSection: some View {
        VStack(alignment: .leading, spacing: 30) {
            searchField
                .padding(.horizontal, 60)

            if !searchedQuery.isEmpty {
                if search.items.isEmpty {
                    Text("Nothing on \(session.applicationTitle) for \u{201C}\(searchedQuery)\u{201D}")
                        .font(Typography.bodySmall)
                        .foregroundStyle(SashimiTheme.textTertiary)
                        .padding(.horizontal, 60)
                } else {
                    SeerrSearchRow(title: "Results for \u{201C}\(searchedQuery)\u{201D}", items: search.items) { item in
                        openTarget = item.target
                    }
                }
            }

            if discover.rows.isEmpty {
                if discover.isLoading || !discover.hasLoaded {
                    ProgressView()
                        .tint(SashimiTheme.accent)
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if let error = discover.errorMessage {
                    ErrorStateView(title: "Couldn't load Discover", message: error) {
                        Task { await discover.load() }
                    }
                }
            } else {
                ForEach(discover.rows) { row in
                    SeerrDiscoverRowView(row: row) { item in
                        openTarget = item.target
                    } onAppear: { item in
                        Task { await discover.loadMoreIfNeeded(row.slider, after: item) }
                    }
                }
            }
        }
        .task(id: session.requestsRevision) { await discover.load() }
    }

    private var searchField: some View {
        HStack(spacing: 20) {
            TextField("Search \(session.applicationTitle) for a movie or show", text: $query)
                .font(Typography.body)
                .frame(maxWidth: 900)
                .onSubmit { runSearch() }
            if !searchedQuery.isEmpty {
                GuideChip(label: "Clear", systemImage: "xmark", selected: false) { clearSearch() }
            }
        }
        .focusSection()
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchedQuery = trimmed
        Task { await search.search(query: trimmed, library: []) }
    }

    private func clearSearch() {
        query = ""
        searchedQuery = ""
        search.clear()
    }
}

/// One Discover row: posters with their request state, paging on near the end.
struct SeerrDiscoverRowView: View {
    let row: SeerrDiscoverRow
    let onSelect: (SeerrSearchItem) -> Void
    let onAppear: (SeerrSearchItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(row.title)
                .font(Typography.headlineSmall)
                .foregroundStyle(SashimiTheme.textPrimary)
                .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(row.items) { item in
                        SeerrPosterButton(
                            title: item.result.year.map { "\(item.result.title) (\($0))" } ?? item.result.title,
                            posterPath: item.result.posterPath,
                            tag: item.discoverTag.map { ($0.label, $0.tone.color) },
                            width: Sizing.posterWidth
                        ) {
                            onSelect(item)
                        }
                        .onAppear { onAppear(item) }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
            }
            .focusSection()
        }
    }
}

extension View {
    /// Claims the rail's default focus when it supplies its namespace.
    @ViewBuilder
    func requestsDefaultFocus(_ isDefault: Bool, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            prefersDefaultFocus(isDefault, in: namespace)
        } else {
            self
        }
    }
}

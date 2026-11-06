import SwiftUI

/// The Requests page on iPhone, iPad and Mac (#845), modelled on Seerr's
/// website: Discover (rows of titles to request, and a search) and Requests
/// (the request list, with approve and decline for those allowed). In the
/// iPad/Mac side menu and the iPhone's Libraries tab while a Seerr account is
/// connected; an expired sign-in shows the sign-in form here instead.
struct MobileRequestsPage: View {
    enum Section: String, CaseIterable, Identifiable {
        case discover
        case requests

        var id: String { rawValue }
        var title: String { self == .discover ? "Discover" : "Requests" }
    }

    @ObservedObject private var session = SeerrSession.shared
    @State private var section: Section = .discover
    @State private var openTarget: SeerrTarget?

    var body: some View {
        Group {
            if session.state == .expired {
                MobileRequestsSettingsView()
            } else {
                VStack(spacing: 0) {
                    Picker("Section", selection: $section) {
                        ForEach(Section.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, MobileSpacing.md)
                    .padding(.vertical, MobileSpacing.sm)

                    switch section {
                    case .discover:
                        MobileSeerrDiscoverView { openTarget = $0 }
                    case .requests:
                        MobileSeerrRequestListView { openTarget = $0 }
                    }
                }
            }
        }
        .background(MobileColors.background)
        .navigationTitle("Requests")
        .navigationDestination(item: $openTarget) { target in
            MobileSeerrDetailView(target: target)
        }
    }
}

/// Discover: a search, then Seerr's rows, each paging on near its end.
struct MobileSeerrDiscoverView: View {
    let onOpen: (SeerrTarget) -> Void

    @ObservedObject private var session = SeerrSession.shared
    @StateObject private var model = SeerrDiscoverModel()
    @StateObject private var search = SeerrSearchModel(includesAvailable: true)
    @State private var query = ""
    @State private var searchedQuery = ""

    private var cardWidth: CGFloat {
        MobileLayoutIdiom.usesPadLayout ? MobileSizing.posterWidth : PhoneSizing.posterWidth
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileSpacing.lg) {
                searchField
                    .padding(.horizontal, MobileSpacing.md)

                if !searchedQuery.isEmpty {
                    if search.items.isEmpty {
                        Text("Nothing on \(session.applicationTitle) for \u{201C}\(searchedQuery)\u{201D}")
                            .font(MobileTypography.caption)
                            .foregroundStyle(MobileColors.textTertiary)
                            .padding(.horizontal, MobileSpacing.md)
                    } else {
                        MobileSeerrSearchRow(title: "Results", items: search.items, cardWidth: cardWidth) { onOpen($0.target) }
                    }
                }

                if model.rows.isEmpty {
                    if model.isLoading || !model.hasLoaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, MobileSpacing.xl)
                    } else if let error = model.errorMessage {
                        ContentUnavailableView("Couldn't Load Discover", systemImage: "exclamationmark.triangle", description: Text(error))
                    }
                } else {
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                }
            }
            .padding(.vertical, MobileSpacing.sm)
        }
        .refreshable { await model.load() }
        .task(id: session.requestsRevision) { await model.load() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(MobileColors.textTertiary)
            TextField("Search \(session.applicationTitle)", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(runSearch)
            if !query.isEmpty {
                Button {
                    query = ""
                    searchedQuery = ""
                    search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(MobileColors.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(MobileColors.cardBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchedQuery = trimmed
        Task { await search.search(query: trimmed, library: []) }
    }

    private func rowView(_ row: SeerrDiscoverRow) -> some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text(row.title)
                .font(MobileTypography.headlineSmall)
                .foregroundStyle(MobileColors.textPrimary)
                .padding(.horizontal, MobileSpacing.md)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: MobileSpacing.sm) {
                    ForEach(row.items) { item in
                        Button {
                            onOpen(item.target)
                        } label: {
                            MobileSeerrPosterCard(
                                title: item.result.year.map { "\(item.result.title) (\($0))" } ?? item.result.title,
                                posterPath: item.result.posterPath,
                                tag: item.discoverTag.map { ($0.label, $0.tone.color) },
                                width: cardWidth
                            )
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            Task { await model.loadMoreIfNeeded(row.slider, after: item) }
                        }
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
            }
        }
    }
}

import SwiftUI

/// Your requests on iPhone and iPad: the person's own requests and where
/// each stands. Ready ones open the library title; pending ones can be
/// cancelled with a swipe or from the row's menu.
struct MobileSeerrRequestsView: View {
    @StateObject private var model = SeerrRequestsModel()
    @ObservedObject private var session = SeerrSession.shared
    @State private var openTarget: SeerrTarget?
    @State private var openItem: BaseItemDto?
    @State private var cancelling: SeerrRequestRow?

    var body: some View {
        Group {
            if model.rows.isEmpty {
                if model.isLoading || !model.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.errorMessage {
                    ContentUnavailableView("Couldn't Load Requests", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ContentUnavailableView(
                        "No Requests Yet",
                        systemImage: "tray",
                        description: Text("Search for something that isn't in your library to request it.")
                    )
                }
            } else {
                List(model.rows) { row in
                    Button {
                        Task { await open(row) }
                    } label: {
                        MobileSeerrRequestRow(row: row)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(MobileColors.cardBackground)
                    .swipeActions {
                        if row.canCancel {
                            Button("Cancel Request", role: .destructive) { cancelling = row }
                        }
                    }
                    .contextMenu {
                        if row.canCancel {
                            Button("Cancel Request", systemImage: "xmark.circle", role: .destructive) { cancelling = row }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await model.load() }
            }
        }
        .background(MobileColors.background)
        .navigationTitle("Your Requests")
        .task(id: session.requestsRevision) { await model.load() }
        .navigationDestination(item: $openTarget) { target in
            MobileSeerrDetailView(target: target)
        }
        .navigationDestination(item: $openItem) { item in
            AdaptiveDetailView(item: item, libraryName: item.libraryName)
        }
        .confirmationDialog(
            "Cancel this request?",
            isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }),
            titleVisibility: .visible,
            presenting: cancelling
        ) { row in
            Button("Cancel Request", role: .destructive) {
                Task { await model.cancel(row) }
            }
            Button("Keep It", role: .cancel) {}
        } message: { row in
            Text(row.displayTitle)
        }
    }

    private func open(_ row: SeerrRequestRow) async {
        if row.state == .ready,
           let item = await SeerrDetailModel.findInLibrary(tmdbId: row.tmdbId, kind: row.kind, title: row.title) {
            openItem = item
        } else {
            openTarget = row.target
        }
    }
}

struct MobileSeerrRequestRow: View {
    let row: SeerrRequestRow

    var body: some View {
        HStack(spacing: MobileSpacing.sm) {
            SeerrArtwork(url: SeerrImages.poster(row.posterPath, width: 185), title: "", cornerRadius: 6)
                .frame(width: 44, height: 66)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayTitle)
                    .font(MobileTypography.title)
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(2)
                Text(row.subtitle)
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: MobileSpacing.xs)
            SeerrStatusTag(label: row.state.label, color: row.state.color, fontSize: 11)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A poster card for a title that isn't on the server, with its state pill.
struct MobileSeerrPosterCard: View {
    let title: String
    let posterPath: String?
    let tag: (label: String, color: Color)
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SeerrArtwork(url: SeerrImages.poster(posterPath, width: 342), title: title)
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .topTrailing) {
                    SeerrStatusTag(label: tag.label, color: tag.color, fontSize: 10, onArtwork: true)
                        .padding(5)
                }
            Text(title)
                .font(MobileTypography.captionSmall)
                .foregroundStyle(MobileColors.textSecondary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(tag.label)")
    }
}

/// Search's "Not in your library" row (mockup F).
struct MobileSeerrSearchRow: View {
    let title: String
    let items: [SeerrSearchItem]
    let cardWidth: CGFloat
    let onSelect: (SeerrSearchItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            Text(title)
                .font(MobileTypography.headlineSmall)
                .foregroundStyle(MobileColors.textPrimary)
                .padding(.horizontal, MobileSpacing.md)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: MobileSpacing.sm) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            MobileSeerrPosterCard(
                                title: item.result.year.map { "\(item.result.title) (\($0))" } ?? item.result.title,
                                posterPath: item.result.posterPath,
                                tag: (item.badge.label, item.badge.color),
                                width: cardWidth
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
            }
        }
    }
}

/// Home's "Your requests" row: only with a Seerr account, and only while
/// something waits or arrived in the last week. Ready items open the
/// library title.
struct MobileSeerrHomeRow: View {
    let cardWidth: CGFloat
    @StateObject private var requests = SeerrRequestsModel()
    @ObservedObject private var session = SeerrSession.shared
    @State private var openTarget: SeerrTarget?
    @State private var openItem: BaseItemDto?

    var body: some View {
        // Zero height when there's nothing to show; the row brings its own
        // gap above it so Home's spacing is unchanged otherwise.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if session.isActive, !requests.homeRows.isEmpty {
                VStack(alignment: .leading, spacing: MobileSpacing.sm) {
                    Text("Your Requests")
                        .font(MobileTypography.headline)
                        .foregroundStyle(MobileColors.textPrimary)
                        .padding(.horizontal, MobileSpacing.md)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: MobileSpacing.sm) {
                            ForEach(requests.homeRows) { row in
                                Button {
                                    Task { await open(row) }
                                } label: {
                                    MobileSeerrPosterCard(
                                        title: row.displayTitle,
                                        posterPath: row.posterPath,
                                        tag: (row.state.label, row.state.color),
                                        width: cardWidth
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, MobileSpacing.md)
                    }
                }
                .padding(.top, MobileSpacing.lg)
            }
        }
        .task(id: "\(session.isActive)-\(session.requestsRevision)") {
            await requests.load()
        }
        .navigationDestination(item: $openTarget) { target in
            MobileSeerrDetailView(target: target)
        }
        .navigationDestination(item: $openItem) { item in
            AdaptiveDetailView(item: item, libraryName: item.libraryName)
        }
    }

    private func open(_ row: SeerrRequestRow) async {
        if row.state == .ready,
           let item = await SeerrDetailModel.findInLibrary(tmdbId: row.tmdbId, kind: row.kind, title: row.title) {
            openItem = item
        } else {
            openTarget = row.target
        }
    }
}

/// Your requests from the profile menu, as a sheet with its own stack.
struct MobileSeerrRequestsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MobileSeerrRequestsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .dismissesOnOutsideTap()
    }
}

/// Shows Your requests from a profile menu. The menu's content is torn down
/// when it closes, so the sheet hangs off the screen and this flag.
@MainActor
final class SeerrRequestsPresenter: ObservableObject {
    static let shared = SeerrRequestsPresenter()
    @Published var isPresented = false
}

/// "Your Requests" in the profile/server menu, only with a Seerr account.
struct SeerrRequestsMenuItem: View {
    @ObservedObject private var session = SeerrSession.shared

    var body: some View {
        if session.isActive {
            Button {
                SeerrRequestsPresenter.shared.isPresented = true
            } label: {
                Label("Your Requests", systemImage: "tray.full")
            }
        }
    }
}

private struct SeerrRequestsSheetModifier: ViewModifier {
    @ObservedObject private var presenter = SeerrRequestsPresenter.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: $presenter.isPresented) {
            MobileSeerrRequestsSheet()
        }
    }
}

private struct SeerrDetailCoverModifier: ViewModifier {
    @Binding var item: SeerrTarget?

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $item) { target in
            NavigationStack {
                MobileSeerrDetailView(target: target)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                item = nil
                            } label: {
                                Label("Back", systemImage: "chevron.left")
                            }
                        }
                    }
            }
        }
    }
}

extension View {
    /// Where the profile menu's "Your Requests" opens.
    func seerrRequestsSheet() -> some View {
        modifier(SeerrRequestsSheetModifier())
    }

    /// A request page over the screen, with its own navigation stack.
    func seerrDetailCover(item: Binding<SeerrTarget?>) -> some View {
        modifier(SeerrDetailCoverModifier(item: item))
    }
}

import SwiftUI

/// A poster card for a title that isn't on the server, with its state pill.
struct MobileSeerrPosterCard: View {
    let title: String
    let posterPath: String?
    let tag: (label: String, color: Color)?
    let width: CGFloat
    /// A second line under the title (who asked, on Home's requests row).
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SeerrArtwork(url: SeerrImages.poster(posterPath, width: 342), title: title)
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .topTrailing) {
                    if let tag {
                        SeerrStatusTag(label: tag.label, color: tag.color, fontSize: 10, onArtwork: true)
                            .padding(5)
                    }
                }
            Text(title)
                .font(MobileTypography.captionSmall)
                .foregroundStyle(MobileColors.textSecondary)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
            if let subtitle {
                Text(subtitle)
                    .font(MobileTypography.captionSmall)
                    .foregroundStyle(MobileColors.textTertiary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(([title, tag?.label, subtitle.map { "requested by \($0)" }] as [String?]).compactMap { $0 }.joined(separator: ", "))
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
                    Text(requests.title)
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
                                        width: cardWidth,
                                        subtitle: requests.requester(of: row)
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
    /// A request page over the screen, with its own navigation stack.
    func seerrDetailCover(item: Binding<SeerrTarget?>) -> some View {
        modifier(SeerrDetailCoverModifier(item: item))
    }
}

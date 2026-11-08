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

/// Home's requests row (#861): a Home row like any other, drawn where its
/// config sits. Home owns `requests` and only includes this view while
/// `requests.showsHomeRow`, so an empty row leaves no gap; the loading and
/// the pages it opens are `seerrHomeRequests(_:target:item:)` on Home
/// itself, so they carry on while the row is not drawn. Ready items open
/// the library title.
struct MobileSeerrHomeRow: View {
    @ObservedObject var requests: SeerrRequestsModel
    let cardWidth: CGFloat
    @Binding var openTarget: SeerrTarget?
    @Binding var openItem: BaseItemDto?

    var body: some View {
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

extension View {
    /// Keeps Home's requests row loaded (on sign-in and after any request
    /// changes) and pushes the page a card opens (#861).
    func seerrHomeRequests(_ requests: SeerrRequestsModel, target: Binding<SeerrTarget?>, item: Binding<BaseItemDto?>) -> some View {
        modifier(SeerrHomeRequestsModifier(requests: requests, target: target, item: item))
    }
}

private struct SeerrHomeRequestsModifier: ViewModifier {
    @ObservedObject var requests: SeerrRequestsModel
    @Binding var target: SeerrTarget?
    @Binding var item: BaseItemDto?
    @ObservedObject private var session = SeerrSession.shared

    func body(content: Content) -> some View {
        content
            .task(id: "\(session.isActive)-\(session.requestsRevision)") {
                await requests.load()
            }
            .navigationDestination(item: $target) { target in
                MobileSeerrDetailView(target: target)
            }
            .navigationDestination(item: $item) { item in
                AdaptiveDetailView(item: item, libraryName: item.libraryName)
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

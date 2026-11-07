import SwiftUI

/// A poster for a title that isn't on the server, with its request state as
/// a pill in the corner (mockup B). Focus treatment matches MediaPosterButton.
struct SeerrPosterButton: View {
    let title: String
    let posterPath: String?
    let tag: (label: String, color: Color)?
    var width: CGFloat = 200
    let action: () -> Void

    @FocusState private var isFocused: Bool

    private var height: CGFloat { width * 1.5 }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                SeerrArtwork(
                    url: SeerrImages.poster(posterPath, width: 342),
                    title: title,
                    cornerRadius: 12,
                    titleFont: .system(size: 22, weight: .bold)
                )
                .frame(width: width, height: height)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 4)
                )
                .overlay(alignment: .topTrailing) {
                    if let tag {
                        SeerrStatusTag(label: tag.label, color: tag.color, fontSize: 17, onArtwork: true)
                            .padding(9)
                    }
                }
                .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 15)

                MarqueeText(text: title, isScrolling: isFocused, height: 24, alignment: .center)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .frame(width: width, alignment: .center)
            }
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tag.map { "\(title), \($0.label)" } ?? title)
    }
}

/// Search's "Not in your library · from MondoVision" row (mockup B).
struct SeerrSearchRow: View {
    let title: String
    let items: [SeerrSearchItem]
    let onSelect: (SeerrSearchItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text(title)
                    .font(Typography.headlineSmall)
                    .foregroundStyle(SashimiTheme.textPrimary)
                Text("\u{00B7} \(items.count)")
                    .font(.subheadline)
                    .foregroundStyle(SashimiTheme.textTertiary)
            }
            .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(items) { item in
                        SeerrPosterButton(
                            title: item.result.year.map { "\(item.result.title) (\($0))" } ?? item.result.title,
                            posterPath: item.result.posterPath,
                            tag: (item.badge.label, item.badge.color)
                        ) {
                            onSelect(item)
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
            }
            .focusSection()
        }
    }
}

/// The requests row on Home (everyone's or "Your Requests"): only while something waits or arrived in the
/// last week (mockup E). Hidden entirely without a Seerr account.
struct SeerrRequestsHomeRow: View {
    let title: String
    let rows: [SeerrRequestRow]
    let onSelect: (SeerrRequestRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(Typography.headlineSmall)
                .foregroundStyle(SashimiTheme.textPrimary)
                .padding(.horizontal, 80)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    ForEach(rows) { row in
                        SeerrPosterButton(
                            title: row.displayTitle,
                            posterPath: row.posterPath,
                            tag: (row.state.label, row.state.color),
                            width: Sizing.posterWidth
                        ) {
                            onSelect(row)
                        }
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 20)
            }
            .focusSection()
        }
    }
}

/// Home's "Your requests" row with its own loading and the request page it
/// opens. Draws nothing without a Seerr account or anything to show.
struct SeerrHomeSection: View {
    /// A ready request opens the library title through Home's own detail.
    let onOpenLibraryItem: (BaseItemDto) -> Void

    @StateObject private var requests = SeerrRequestsModel()
    @ObservedObject private var session = SeerrSession.shared
    @State private var target: SeerrTarget?

    var body: some View {
        // Zero height when there's nothing to show, so Home keeps its
        // spacing; the row brings its own gap above it.
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            if session.isActive, !requests.homeRows.isEmpty {
                SeerrRequestsHomeRow(title: requests.title, rows: requests.homeRows) { row in
                    Task { await open(row) }
                }
                .padding(.top, 40)
            }
        }
        .task(id: "\(session.isActive)-\(session.requestsRevision)") {
            await requests.load()
        }
        .fullScreenCover(item: $target, onDismiss: {
            Task { await requests.load() }
        }, content: { target in
            SeerrDetailView(target: target)
        })
    }

    private func open(_ row: SeerrRequestRow) async {
        if row.state == .ready,
           let item = await SeerrDetailModel.findInLibrary(tmdbId: row.tmdbId, kind: row.kind, title: row.title) {
            onOpenLibraryItem(item)
        } else {
            target = row.target
        }
    }
}

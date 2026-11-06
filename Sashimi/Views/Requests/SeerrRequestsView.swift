import SwiftUI

/// Your requests (mockup E): the person's own requests and where each one
/// stands. Ready ones open the library title; pending ones can be
/// cancelled (press and hold).
struct SeerrRequestsView: View {
    @StateObject private var model = SeerrRequestsModel()
    @ObservedObject private var session = SeerrSession.shared
    @State private var openTarget: SeerrTarget?
    @State private var openItem: BaseItemDto?
    @State private var cancelling: SeerrRequestRow?

    private let columns = [GridItem(.flexible(), spacing: 30), GridItem(.flexible(), spacing: 30)]

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()
            content
        }
        .task(id: session.requestsRevision) { await model.load() }
        .fullScreenCover(item: $openTarget) { target in
            SeerrDetailView(target: target)
        }
        .fullScreenCover(item: $openItem) { item in
            MediaDetailView(item: item)
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

    @ViewBuilder
    private var content: some View {
        if model.rows.isEmpty {
            if model.isLoading || !model.hasLoaded {
                ProgressView().tint(SashimiTheme.accent).scaleEffect(1.5)
            } else if let error = model.errorMessage {
                ErrorStateView(title: "Couldn't load your requests", message: error) {
                    Task { await model.load() }
                }
            } else {
                EmptyStateView(
                    icon: "tray",
                    title: "No requests yet",
                    message: "Search for something that isn't in your library to request it."
                )
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Text("Your Requests")
                        .font(Typography.headline)
                        .foregroundStyle(SashimiTheme.textPrimary)
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(model.rows) { row in
                            SeerrRequestCard(row: row) {
                                Task { await open(row) }
                            } onCancel: {
                                cancelling = row
                            }
                        }
                    }
                    if model.rows.contains(where: \.canCancel) {
                        Text("Press and hold a pending request to cancel it.")
                            .font(Typography.caption)
                            .foregroundStyle(SashimiTheme.textTertiary)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 60)
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

/// One request: poster, title, how it's going, and its state tag.
struct SeerrRequestCard: View {
    let row: SeerrRequestRow
    let onSelect: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 24) {
                SeerrArtwork(url: SeerrImages.poster(row.posterPath, width: 185), title: "", cornerRadius: 8)
                    .frame(width: 80, height: 120)
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.displayTitle)
                        .font(Typography.titleSmall)
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .lineLimit(2)
                    Text(row.subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(isFocused ? .white.opacity(0.8) : SashimiTheme.textTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 10)
                SeerrStatusTag(label: row.state.label, color: row.state.color, fontSize: 18)
            }
            .padding(16)
            .focusHighlight(isFocused, cornerRadius: CornerRadius.medium)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .contextMenu {
            if row.canCancel {
                Button("Cancel Request", systemImage: "xmark.circle", role: .destructive, action: onCancel)
            }
        }
        .accessibilityLabel("\(row.displayTitle), \(row.state.label), \(row.subtitle)")
    }
}

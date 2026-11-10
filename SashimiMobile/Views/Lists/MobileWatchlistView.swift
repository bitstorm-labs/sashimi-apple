import NukeUI
import SwiftUI

/// The Watchlist on iPhone, iPad and Mac: "Use Plex too?" (or the Plex sync
/// line), then every title, with those the server doesn't have dimmed and
/// tagged "Not on server" or "Requested".
struct MobileWatchlistView: View {
    @StateObject private var model = WatchlistPageViewModel()
    @StateObject private var connect = PlexConnectModel()
    @Environment(\.dismiss) private var dismiss
    @State private var connectTask: Task<Void, Never>?
    @State private var removing = false
    @State private var removal: WatchlistTile?
    @State private var confirmDisconnect = false
    @State private var message: String?

    private let columns = [GridItem(.adaptive(minimum: PhoneSizing.posterWidth, maximum: MobileSizing.posterWidth),
                                    spacing: MobileSpacing.sm, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileSpacing.md) {
                header
                content
            }
            .padding(MobileSpacing.md)
        }
        .background(MobileColors.background)
        .navigationTitle(WatchlistText.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { menu }
        }
        .listMessage($message)
        .task {
            await model.load()
            await connect.resumePendingIfAny()
        }
        .refreshable { await model.load() }
        .onDisappear {
            model.cancelLookups()
            connectTask?.cancel()
            if connect.isWaiting { connect.cancel() }
        }
        .onChange(of: model.isGone) { _, gone in
            if gone { dismiss() }
        }
        .plexConnectFeedback(connect, message: $message)
        .disconnectPlexConfirmation(isPresented: $confirmDisconnect) {
            Task { if !(await model.disconnect()) { message = "Couldn't disconnect Plex. Try again." } }
        }
        .confirmationDialog(removal?.entry.title ?? "", isPresented: removalShown, titleVisibility: .visible) {
            if let tile = removal {
                Button(WatchlistText.remove, role: .destructive) { remove(tile) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            VStack(alignment: .leading, spacing: MobileSpacing.xxs) {
                Label(WatchlistText.name, systemImage: "bookmark.fill")
                    .font(MobileTypography.displayLarge)
                    .foregroundStyle(MobileColors.textPrimary)
                Text(model.summary)
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textTertiary)
            }
            if connect.isWaiting || connect.state == .linking {
                HStack {
                    ProgressView()
                    Text(connect.state == .linking ? "Connecting…" : "Waiting for Plex…")
                        .font(MobileTypography.bodySmall)
                        .foregroundStyle(MobileColors.textSecondary)
                    Spacer()
                    Button("Cancel") { cancelConnect() }
                }
            } else {
                plexHeader
            }
            if removing {
                HStack {
                    Text("Tap a title to remove it.")
                        .font(MobileTypography.bodySmall)
                        .foregroundStyle(MobileColors.accentSecondary)
                    Spacer()
                    Button("Done") { removing = false }
                }
            }
        }
    }

    @ViewBuilder
    private var plexHeader: some View {
        switch model.header {
        case .connectCard:
            VStack(alignment: .leading, spacing: MobileSpacing.xs) {
                Text(WatchlistText.cardTitle)
                    .font(MobileTypography.title)
                    .foregroundStyle(MobileColors.textPrimary)
                Text(WatchlistText.cardBody)
                    .font(MobileTypography.bodySmall)
                    .foregroundStyle(MobileColors.textSecondary)
                HStack(spacing: MobileSpacing.sm) {
                    Button(WatchlistText.connect) { startConnect() }
                        .buttonStyle(.borderedProminent)
                        .tint(MobileColors.accent)
                    Button(WatchlistText.notNow) { Task { await model.dismissCard() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(MobileColors.textSecondary)
                }
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, MobileSpacing.xxs)
            }
            .padding(MobileSpacing.sm)
            .frame(maxWidth: 560, alignment: .leading)
            .background(Color(red: 0.11, green: 0.16, blue: 0.23), in: RoundedRectangle(cornerRadius: MobileCornerRadius.large))
        case .synced:
            Label(WatchlistText.synced, systemImage: "checkmark")
                .font(MobileTypography.bodySmall.weight(.semibold))
                .foregroundStyle(Color(red: 0.62, green: 0.86, blue: 0.70))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: 560, alignment: .leading)
                .background(Color(red: 0.09, green: 0.15, blue: 0.11), in: RoundedRectangle(cornerRadius: MobileCornerRadius.medium))
        case .needsReconnect:
            HStack(spacing: MobileSpacing.sm) {
                Label(WatchlistText.stoppedSyncing, systemImage: "exclamationmark.triangle.fill")
                    .font(MobileTypography.bodySmall.weight(.semibold))
                    .foregroundStyle(MobileColors.warning)
                Button(WatchlistText.reconnect) { startConnect() }
                    .buttonStyle(.bordered)
                    .font(.system(size: 14, weight: .semibold))
            }
        case .none:
            EmptyView()
        }
    }

    private var menu: some View {
        Menu {
            ForEach(model.menuItems, id: \.self) { item in
                switch item {
                case .connectPlex:
                    Button { startConnect() } label: { Label(WatchlistText.connect, systemImage: "link") }
                case .reconnectPlex:
                    Button { startConnect() } label: { Label(WatchlistText.reconnect, systemImage: "arrow.clockwise") }
                case .disconnectPlex:
                    Button(role: .destructive) { confirmDisconnect = true } label: {
                        Label(WatchlistText.disconnect, systemImage: "xmark.circle")
                    }
                case .removeTitles:
                    Button { removing = true } label: { Label("Remove a Title", systemImage: "minus.circle") }
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    // MARK: Titles

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else if model.tiles.isEmpty {
            Text(model.failed ? "Couldn't load your Watchlist." : WatchlistText.empty)
                .font(MobileTypography.body)
                .foregroundStyle(MobileColors.textTertiary)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: MobileSpacing.md) {
                ForEach(model.tiles) { tile in
                    tileLink(tile)
                        .onAppear { model.tileAppeared(tile) }
                }
            }
        }
    }

    @ViewBuilder
    private func tileLink(_ tile: WatchlistTile) -> some View {
        let label = WatchlistTileView(tile: tile)
        if removing {
            Button { removal = tile } label: { label }
                .buttonStyle(.plain)
        } else {
            Group {
                switch model.action(for: tile) {
                case .openLibrary(let item):
                    NavigationLink { AdaptiveDetailView(item: item, libraryName: item.libraryName) } label: { label }
                case .openRequest(let target):
                    NavigationLink { MobileSeerrDetailView(target: target) } label: { label }
                case .explain(let text):
                    Button { message = text } label: { label }
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(WatchlistText.remove, systemImage: "minus.circle", role: .destructive) { remove(tile) }
            }
        }
    }

    private var removalShown: Binding<Bool> {
        Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
    }

    private func remove(_ tile: WatchlistTile) {
        Task {
            if !(await model.remove(tile)) { message = "Couldn't change the Watchlist" }
        }
    }

    private func startConnect() {
        connectTask?.cancel()
        connectTask = Task { await connectPlex(model: connect) }
    }

    private func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        connect.cancel()
    }
}

/// One Watchlist poster. Titles the server doesn't have keep their poster,
/// dimmed and grey, with the tag laid over it undimmed.
struct WatchlistTileView: View {
    let tile: WatchlistTile
    var width: CGFloat = PhoneSizing.posterWidth

    private var titleFontSize: CGFloat { min(16, max(13, width * 0.095)) }

    var body: some View {
        if let item = tile.libraryItem {
            ListPosterCard(item: item, width: width, isNew: false)
        } else {
            VStack(alignment: .leading, spacing: MobileSpacing.xs) {
                WatchlistArtworkView(artwork: tile.artwork, title: tile.entry.title, width: width)
                    .grayscale(1)
                    .brightness(-0.45)
                    .frame(width: width, height: width / PosterAspectRatio.portrait)
                    .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.medium))
                    .overlay(alignment: .topLeading) {
                        if let tag = tile.missingTag {
                            Text(tag.label)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                                .padding(6)
                        }
                    }
                Text(tile.entry.title)
                    .font(.system(size: titleFontSize, weight: .medium))
                    .foregroundStyle(MobileColors.textSecondary)
                    .lineLimit(1)
                    .frame(width: width, height: titleFontSize + 5, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(tile.entry.title), \(tile.missingTag?.label ?? "")")
        }
    }
}

/// A Watchlist poster: the server's own, the one saved with the title, or the
/// title standing in.
struct WatchlistArtworkView: View {
    let artwork: WatchlistArtwork
    let title: String
    let width: CGFloat

    var body: some View {
        switch artwork {
        case .library(let itemId):
            ZStack {
                MobileColors.cardBackground
                LazyImage(url: JellyfinClient.shared.syncImageURL(
                    itemId: itemId, imageType: "Primary", maxWidth: ImageSizing.pixelWidth(points: width)
                )) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    }
                }
                .pipeline(SashimiImagePipeline.shared)
            }
        case .remote(let url):
            SeerrArtwork(url: url, title: title, cornerRadius: 0)
        case .none:
            SeerrArtwork(url: nil, title: title, cornerRadius: 0)
        }
    }
}

/// The Watchlist's card, first under "Your lists".
struct MobileWatchlistCard: View {
    let card: WatchlistCardInfo

    var body: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.xxs) {
            cover
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Label(WatchlistText.name, systemImage: "bookmark.fill")
                .font(MobileTypography.title)
                .foregroundStyle(MobileColors.textPrimary)
                .lineLimit(1)
            Text(card.subtitle)
                .font(MobileTypography.caption)
                .foregroundStyle(MobileColors.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var cover: some View {
        GeometryReader { geometry in
            ZStack {
                MobileColors.cardBackground
                if card.cover.count == 4 {
                    let cell = CGSize(width: geometry.size.width / 2, height: geometry.size.height / 2)
                    VStack(spacing: 0) {
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(0..<2, id: \.self) { column in
                                    WatchlistArtworkView(artwork: card.cover[row * 2 + column], title: "", width: cell.width)
                                        .frame(width: cell.width, height: cell.height)
                                        .clipped()
                                }
                            }
                        }
                    }
                } else if let first = card.cover.first {
                    WatchlistArtworkView(artwork: first, title: "", width: geometry.size.width)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    Image(systemName: "bookmark")
                        .font(.system(size: 30))
                        .foregroundStyle(MobileColors.textTertiary)
                }
            }
        }
    }
}

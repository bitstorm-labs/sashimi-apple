import SwiftUI

/// The Watchlist on Apple TV: "Use Plex too?" (or the Plex sync line), then
/// every title, with those the server doesn't have dimmed and tagged "Not on
/// server" or "Requested". Remove a Title works as Edit List's does.
struct WatchlistPageView: View {
    @StateObject private var model = WatchlistPageViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var selected: BaseItemDto?
    @State private var request: SeerrTarget?
    @State private var connecting = false
    @State private var removing = false
    @State private var removal: WatchlistTile?
    @State private var confirmDisconnect = false
    @FocusState private var menuFocused: Bool

    private let columns = Array(repeating: GridItem(.fixed(220), spacing: 48, alignment: .top), count: 6)

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    header
                    content
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 60)
            }
            .scrollClipDisabled()
        }
        .fullScreenCover(item: $selected) { item in
            MediaDetailView(item: item)
        }
        .fullScreenCover(item: $request) { target in
            SeerrDetailView(target: target)
        }
        .fullScreenCover(isPresented: $connecting) {
            WatchlistPlexConnectView()
        }
        .onChange(of: selected) { old, new in
            if old != nil && new == nil { Task { await model.load() } }
        }
        .onChange(of: request) { old, new in
            if old != nil && new == nil { Task { await model.load() } }
        }
        // Connect Plex's cover hid the page too: reload, so lookups cut short resume.
        .onChange(of: connecting) { old, new in
            if old && !new { Task { await model.load() } }
        }
        .confirmationDialog(removal?.entry.title ?? "", isPresented: removalShown, titleVisibility: .visible) {
            if let tile = removal {
                Button(WatchlistText.remove, role: .destructive) { remove(tile) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .destructiveConfirmation(
            WatchlistText.disconnectQuestion,
            isPresented: $confirmDisconnect,
            message: WatchlistText.disconnectMessage,
            confirmTitle: WatchlistText.disconnect
        ) {
            Task {
                if !(await model.disconnect()) { ToastManager.shared.show(WatchlistText.couldntDisconnect) }
            }
        }
        .onExitCommand {
            if removing { removing = false } else { dismiss() }
        }
        .task { await model.load() }
        .resumingPlexConnect()
        // A full-screen cover hides the app root's toasts: show them here too.
        .toastOverlay()
        .onDisappear { model.cancelLookups() }
        .onChange(of: model.isGone) { _, gone in
            if gone { dismiss() }
        }
        .onChange(of: model.tiles.isEmpty) { _, empty in
            if empty { removing = false }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(WatchlistText.name, systemImage: "bookmark.fill")
                .font(Typography.displayMedium)
                .foregroundStyle(SashimiTheme.textPrimary)
            Text(model.summary)
                .font(.system(size: 22))
                .foregroundStyle(SashimiTheme.textTertiary)

            plexLine
                .padding(.top, 10)

            HStack(spacing: 30) {
                switch model.header {
                case .connectCard:
                    ActionButton(title: WatchlistText.connect, icon: "link", isPrimary: true) { connecting = true }
                    ActionButton(title: WatchlistText.notNow, icon: "xmark") {
                        Task { await model.dismissCard() }
                    }
                case .needsReconnect:
                    ActionButton(title: WatchlistText.reconnect, icon: "arrow.clockwise", isPrimary: true) {
                        connecting = true
                    }
                case .synced, .none:
                    EmptyView()
                }
                moreMenu
                Spacer()
            }
            .padding(.top, 10)
            .focusSection()

            if removing {
                Text(WatchlistText.selectToRemove)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SashimiTheme.accentSecondary)
            }
        }
    }

    @ViewBuilder
    private var plexLine: some View {
        switch model.header {
        case .connectCard:
            VStack(alignment: .leading, spacing: 10) {
                Text(WatchlistText.cardTitle)
                    .font(Typography.title)
                    .foregroundStyle(SashimiTheme.textPrimary)
                Text(WatchlistText.cardBody)
                    .font(Typography.bodySmall)
                    .foregroundStyle(SashimiTheme.textSecondary)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .frame(maxWidth: 1000, alignment: .leading)
            .background(SashimiTheme.plexCardBackground, in: RoundedRectangle(cornerRadius: CornerRadius.large))
        case .synced:
            Label(WatchlistText.synced, systemImage: "checkmark")
                .font(Typography.bodySmall.weight(.semibold))
                .foregroundStyle(SashimiTheme.syncedText)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(SashimiTheme.syncedBackground, in: RoundedRectangle(cornerRadius: CornerRadius.medium))
        case .needsReconnect:
            Label(WatchlistText.stoppedSyncing, systemImage: "exclamationmark.triangle.fill")
                .font(Typography.bodySmall.weight(.semibold))
                .foregroundStyle(SashimiTheme.warning)
        case .none:
            EmptyView()
        }
    }

    private var moreMenu: some View {
        Menu {
            ForEach(model.menuItems, id: \.self) { item in
                switch item {
                case .connectPlex:
                    Button { connecting = true } label: { Label(WatchlistText.connect, systemImage: "link") }
                case .reconnectPlex:
                    Button { connecting = true } label: { Label(WatchlistText.reconnect, systemImage: "arrow.clockwise") }
                case .disconnectPlex:
                    Button(role: .destructive) { confirmDisconnect = true } label: {
                        Label(WatchlistText.disconnect, systemImage: "xmark.circle")
                    }
                case .removeTitles:
                    Button { removing = true } label: { Label(WatchlistText.removeATitle, systemImage: "minus.circle") }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline)
                .fontWeight(.semibold)
                .frame(height: 30)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(SashimiTheme.cardBackground, in: Capsule())
                .overlay(Capsule().stroke(menuFocused ? SashimiTheme.focus : .clear, lineWidth: 3))
                .shadow(color: menuFocused ? SashimiTheme.focusGlow : .clear, radius: 12)
                .scaleEffect(menuFocused ? 1.05 : 1.0)
                .animation(.spring(response: 0.3), value: menuFocused)
        }
        .focused($menuFocused)
        .menuStyle(.borderlessButton)
        .accessibilityLabel("More")
    }

    // MARK: Titles

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView()
                .focusable()
                .focusEffectDisabled()
        } else if model.tiles.isEmpty {
            Text(model.failed ? WatchlistText.couldntLoad : WatchlistText.empty)
                .font(Typography.body)
                .foregroundStyle(SashimiTheme.textTertiary)
                .focusable()
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 50) {
                ForEach(model.tiles) { tile in
                    tileButton(tile)
                        .opacity(model.isRemoving(tile) ? 0.4 : 1)
                        .onAppear { model.tileAppeared(tile) }
                }
            }
            .focusSection()
        }
    }

    @ViewBuilder
    private func tileButton(_ tile: WatchlistTile) -> some View {
        if let item = tile.libraryItem {
            MediaPosterButton(item: item, libraryName: item.libraryName) { select(tile) }
        } else {
            WatchlistMissingTileButton(tile: tile) { select(tile) }
        }
    }

    private func select(_ tile: WatchlistTile) {
        if removing {
            removal = tile
            return
        }
        switch model.action(for: tile) {
        case .openLibrary(let item): selected = item
        case .openRequest(let target): request = target
        case .explain(let text): ToastManager.shared.show(text, type: .info)
        }
    }

    private var removalShown: Binding<Bool> {
        Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
    }

    private func remove(_ tile: WatchlistTile) {
        Task {
            if !(await model.remove(tile)) { ToastManager.shared.show(WatchlistText.couldntChange) }
        }
    }
}

/// A title the server doesn't have: its poster dimmed and grey, the tag laid
/// over it undimmed. Focusable like any poster, so it can be opened or removed.
struct WatchlistMissingTileButton: View {
    let tile: WatchlistTile
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(alignment: .center, spacing: 10) {
                WatchlistArtworkImage(artwork: tile.artwork, title: tile.entry.title, width: 220)
                    .grayscale(1)
                    .brightness(-0.45)
                    .frame(width: 220, height: 330)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        if let tag = tile.missingTag {
                            SeerrStatusTag(label: tag.label, color: .white, fontSize: 18, onArtwork: true)
                                .padding(10)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 4)
                    )
                    .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 15)
                Text(tile.entry.title)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .lineLimit(1)
                    .frame(width: 220, height: 24, alignment: .center)
            }
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tile.entry.title), \(tile.missingTag?.label ?? WatchlistText.notOnServer)")
    }
}

/// A Watchlist poster: the server's own, the one saved with the title, or the
/// title standing in.
struct WatchlistArtworkImage: View {
    let artwork: WatchlistArtwork
    let title: String
    let width: CGFloat

    /// The server had no image for the id: the saved poster instead.
    @State private var serverImageFailed = false

    var body: some View {
        switch artwork {
        case .library(let itemId, let fallback):
            if serverImageFailed {
                SeerrArtwork(url: fallback, title: title, cornerRadius: 0, titleFont: .system(size: 20, weight: .bold))
            } else {
                AsyncItemImage(
                    itemId: itemId,
                    imageType: "Primary",
                    // tvOS draws at 2x.
                    maxWidth: Int(width * 2),
                    contentMode: .fill,
                    onLoadFailed: { serverImageFailed = true }
                )
            }
        case .remote(let url):
            SeerrArtwork(url: url, title: title, cornerRadius: 0, titleFont: .system(size: 20, weight: .bold))
        case .none:
            SeerrArtwork(url: nil, title: title, cornerRadius: 0, titleFont: .system(size: 20, weight: .bold))
        }
    }
}

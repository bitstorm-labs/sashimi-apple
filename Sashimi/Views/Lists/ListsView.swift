import SwiftUI

/// The Lists destination: your lists, then everyone's public lists.
struct ListsView: View {
    var onBackAtRoot: (() -> Void)?
    /// The rail's scope, so Right from the rail lands on the first card.
    var focusNamespace: Namespace.ID?

    @StateObject private var model = ListsPageViewModel()
    @ObservedObject private var store = SharedListsStore.shared
    @ObservedObject private var watchlist = WatchlistStore.shared
    @State private var openList: SharedList?
    @State private var openWatchlist = false
    /// The Watchlist has been asked for once, so the first card (which takes
    /// default focus) is known before the cards appear.
    @State private var watchlistChecked = false
    @State private var creating = false

    private let columns = Array(repeating: GridItem(.fixed(ListCardSize.width), spacing: 50, alignment: .top), count: 4)

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()

            if creating {
                NewListForm(
                    title: "New List",
                    confirmTitle: "Create",
                    isWorking: false
                ) { name, isPublic in
                    Task {
                        if let list = await model.create(name: name, isPublic: isPublic) {
                            ToastManager.shared.show("Created \(list.name)", type: .success)
                            creating = false
                        } else {
                            ToastManager.shared.show("Couldn't create the list")
                        }
                    }
                } onCancel: {
                    creating = false
                }
            } else {
                page
            }
        }
        .fullScreenCover(item: $openList) { list in
            ListDetailView(list: list)
        }
        .fullScreenCover(isPresented: $openWatchlist) {
            WatchlistPageView()
        }
        .onChange(of: openList) { old, new in
            if old != nil && new == nil { Task { await reload() } }
        }
        .onChange(of: openWatchlist) { old, new in
            if old && !new { Task { await reload() } }
        }
        .onExitCommand {
            if creating { creating = false } else { onBackAtRoot?() }
        }
        .task {
            await reload()
            watchlistChecked = true
        }
    }

    private func reload() async {
        async let watchlistLoad: Void = watchlist.refresh()
        await model.load()
        await watchlistLoad
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                Text("Lists")
                    .font(Typography.displayMedium)
                    .foregroundStyle(SashimiTheme.textPrimary)

                if model.isLoading || !watchlistChecked {
                    // Something focusable while loading, or focus falls back
                    // to the rail's first row and takes the selection with it.
                    ProgressView()
                        .focusable()
                        .focusEffectDisabled()
                        .listsDefaultFocus(in: focusNamespace)
                } else {
                    yourLists
                    fromOthers
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 50)
        }
        .scrollClipDisabled()
    }

    private var yourLists: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("Your lists")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 50) {
                    // The Watchlist comes first and takes default focus (index 0).
                    let watchlistCard = watchlist.card
                    if let watchlistCard {
                        WatchlistCardButton(card: watchlistCard) { openWatchlist = true }
                            .listsDefaultFocus(in: focusNamespace)
                    }
                    ForEach(Array(model.mine.enumerated()), id: \.element.id) { index, card in
                        ListCardButton(card: card, isOwn: true, isSubscribed: store.isSubscribed(card.id)) {
                            openList = card.list
                        }
                        .listsDefaultFocus(in: index == 0 && watchlistCard == nil ? focusNamespace : nil)
                    }
                    NewListCard { creating = true }
                        .listsDefaultFocus(in: model.mine.isEmpty && watchlistCard == nil ? focusNamespace : nil)
                }
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private var fromOthers: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("From others")
            if model.others.isEmpty {
                Text(model.failed ? "Couldn't load lists." : "No one has shared a list yet.")
                    .font(Typography.body)
                    .foregroundStyle(SashimiTheme.textTertiary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 50) {
                    ForEach(model.others) { card in
                        ListCardButton(card: card, isOwn: false, isSubscribed: store.isSubscribed(card.id)) {
                            openList = card.list
                        }
                    }
                }
            }
        }
        .focusSection()
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Typography.headlineSmall)
            .foregroundStyle(SashimiTheme.textPrimary)
    }
}

/// A list's card: its cover, name, and who made it with how many titles.
struct ListCardButton: View {
    let card: ListCard
    let isOwn: Bool
    let isSubscribed: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                PosterStackCover(posters: card.coverPosters, placeholder: "list.bullet.rectangle", isFanned: isFocused)
                    .frame(width: ListCardSize.width, height: ListCardSize.coverHeight)
                    .overlay(alignment: .topTrailing) {
                        if isSubscribed {
                            Label("Subscribed", systemImage: "checkmark")
                                .font(.system(size: 18, weight: .bold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.75), in: Capsule())
                                .padding(12)
                        }
                    }
                Text(card.list.name)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .lineLimit(1)
                Text(card.subtitle(isOwn: isOwn))
                    .font(.system(size: 20))
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: ListCardSize.width, alignment: .leading)
            .scaleEffect(isFocused ? 1.04 : 1)
            .animation(Animation.focusSpring, value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityLabel("\(card.list.name), \(card.subtitle(isOwn: isOwn))")
    }
}

/// The Watchlist's card, first under "Your lists": the same frame as a list's.
struct WatchlistCardButton: View {
    let card: WatchlistCardInfo
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                PosterStackCover(posters: card.cover, placeholder: "bookmark", isFanned: isFocused)
                    .frame(width: ListCardSize.width, height: ListCardSize.coverHeight)
                Label(WatchlistText.name, systemImage: "bookmark.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .lineLimit(1)
                Text(card.subtitle)
                    .font(.system(size: 20))
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: ListCardSize.width, alignment: .leading)
            .scaleEffect(isFocused ? 1.04 : 1)
            .animation(Animation.focusSpring, value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityLabel("\(WatchlistText.name), \(card.subtitle)")
    }
}

enum ListCardSize {
    static let width: CGFloat = 400
    static let coverHeight: CGFloat = width / PosterStack.aspectRatio
}

/// A list's cover (design §6, "Poster stack"): the first poster full size, the
/// next two fanned behind it. Fans out a little and lifts the front poster's
/// focus ring when its card is focused.
struct PosterStackCover: View {
    let posters: [ListCoverPoster]
    /// The SF Symbol on the placeholder poster of an empty list.
    let placeholder: String
    let isFanned: Bool

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height * PosterStack.frontHeight
            let width = height * 2 / 3
            let left = geometry.size.width * PosterStack.leadingInset
            ZStack(alignment: .topLeading) {
                if posters.isEmpty {
                    posterFrame(isFront: true) {
                        ZStack {
                            SashimiTheme.cardBackground
                            Image(systemName: placeholder)
                                .font(.system(size: 60))
                                .foregroundStyle(SashimiTheme.textTertiary)
                        }
                    }
                    .frame(width: width, height: height)
                    .offset(x: left, y: (geometry.size.height - height) / 2)
                }
                ForEach(PosterStack.layers(count: posters.count, fanned: isFanned), id: \.index) { layer in
                    let poster = posters[layer.index]
                    posterFrame(isFront: layer.index == 0) {
                        WatchlistArtworkImage(artwork: poster.artwork, title: poster.title, width: width)
                            .grayscale(poster.isDimmed ? 1 : 0)
                            .brightness(poster.isDimmed ? -0.45 : 0)
                    }
                    .frame(width: width, height: height)
                    .scaleEffect(layer.scale)
                    .rotationEffect(.degrees(layer.rotation))
                    .opacity(layer.opacity)
                    .offset(x: left + layer.xOffset * width, y: (geometry.size.height - height) / 2)
                }
            }
            .animation(Animation.focusSpring, value: isFanned)
        }
    }

    private func posterFrame<Content: View>(isFront: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFront && isFanned ? SashimiTheme.focus : .clear, lineWidth: 4)
            )
            .shadow(color: isFront ? (isFanned ? SashimiTheme.focusGlow : .black.opacity(0.6)) : .black.opacity(0.4),
                    radius: isFront ? 16 : 8, x: isFront ? 6 : 2)
    }
}

private struct NewListCard: View {
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Label("New List", systemImage: "plus")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(SashimiTheme.textSecondary)
                .frame(width: ListCardSize.width, height: ListCardSize.coverHeight)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isFocused ? SashimiTheme.focus : SashimiTheme.textTertiary,
                                      style: StrokeStyle(lineWidth: isFocused ? 4 : 2, dash: [10, 8]))
                )
                .scaleEffect(isFocused ? 1.04 : 1)
                .animation(Animation.focusSpring, value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
    }
}

extension View {
    /// Default focus in the rail's scope, when one is given.
    @ViewBuilder
    func listsDefaultFocus(in namespace: Namespace.ID?) -> some View {
        if let namespace {
            prefersDefaultFocus(true, in: namespace)
        } else {
            self
        }
    }
}

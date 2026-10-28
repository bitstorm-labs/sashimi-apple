import SwiftUI

/// The Lists destination: your lists, then everyone's public lists.
struct ListsView: View {
    var onBackAtRoot: (() -> Void)?
    /// The rail's scope, so Right from the rail lands on the first card.
    var focusNamespace: Namespace.ID?

    @StateObject private var model = ListsPageViewModel()
    @ObservedObject private var store = SharedListsStore.shared
    @State private var openList: SharedList?
    @State private var creating = false

    private let columns = Array(repeating: GridItem(.fixed(400), spacing: 50, alignment: .top), count: 4)

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
        .onChange(of: openList) { old, new in
            if old != nil && new == nil { Task { await model.load() } }
        }
        .onExitCommand {
            if creating { creating = false } else { onBackAtRoot?() }
        }
        .task { await model.load() }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                Text("Lists")
                    .font(Typography.displayMedium)
                    .foregroundStyle(SashimiTheme.textPrimary)

                if model.isLoading {
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
                    ForEach(Array(model.mine.enumerated()), id: \.element.id) { index, card in
                        ListCardButton(card: card, isOwn: true, isSubscribed: store.isSubscribed(card.id)) {
                            openList = card.list
                        }
                        .listsDefaultFocus(in: index == 0 ? focusNamespace : nil)
                    }
                    NewListCard { creating = true }
                        .listsDefaultFocus(in: model.mine.isEmpty ? focusNamespace : nil)
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
                ListCover(card: card)
                    .frame(width: 400, height: 225)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 4)
                    )
                    .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 16)
                Text(card.list.name)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .lineLimit(1)
                Text(card.subtitle(isOwn: isOwn))
                    .font(.system(size: 20))
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 400, alignment: .leading)
            .scaleEffect(isFocused ? 1.04 : 1)
            .animation(Animation.focusSpring, value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityLabel("\(card.list.name), \(card.subtitle(isOwn: isOwn))")
    }
}

/// Jellyfin's generated playlist image, else the first title's backdrop.
struct ListCover: View {
    let card: ListCard

    var body: some View {
        ZStack {
            SashimiTheme.cardBackground
            if card.list.imageTag != nil {
                AsyncItemImage(itemId: card.list.id, imageType: "Primary", maxWidth: 600)
            } else if let first = card.firstItem {
                AsyncItemImage(
                    itemId: first.type == .episode ? (first.seriesId ?? first.id) : first.id,
                    imageType: "Backdrop",
                    maxWidth: 600,
                    fallbackImageTypes: ["Thumb", "Primary"]
                )
            } else {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 60))
                    .foregroundStyle(SashimiTheme.textTertiary)
            }
        }
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
                .frame(width: 400, height: 225)
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

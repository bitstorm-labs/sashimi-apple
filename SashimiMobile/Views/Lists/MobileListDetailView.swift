import SwiftUI

/// One list: the selected title's Spotlight (backdrop, details, Play) with
/// Subscribe and Shuffle, then its titles as a poster grid. A tap shows a
/// title in the Spotlight; a tap on the title it shows, or Details, opens it. The
/// owner also gets Edit List: rename, public/private, delete, and per title
/// Move Earlier / Later and Remove (long-press a poster, or the Edit menu's
/// Reorder / Remove modes, where a tap acts on the title).
struct MobileListDetailView: View {
    @StateObject private var model: ListDetailViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Editing { case reorder, remove }

    @State private var editing: Editing?
    @State private var actionItem: BaseItemDto?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var message: String?
    @State private var playing: BaseItemDto?
    /// The title the Spotlight shows: the one last tapped, else the first.
    @State private var spotlightId: String?
    /// Taps that selected a title, so the page scrolls back up to it.
    @State private var selectionCount = 0
    @State private var opened: BaseItemDto?

    private let columns = [GridItem(.adaptive(minimum: PhoneSizing.posterWidth, maximum: MobileSizing.posterWidth), spacing: MobileSpacing.sm, alignment: .top)]

    init(list: SharedList) {
        _model = StateObject(wrappedValue: ListDetailViewModel(list: list))
    }

    var body: some View {
        MobileListSpotlightPage(
            eyebrow: model.eyebrow,
            spotlight: spotlightItem.map(ListSpotlight.init(item:)),
            selectionCount: selectionCount,
            actions: { actions },
            notice: { editingHint },
            content: { content }
        )
        .navigationDestination(item: $opened) { item in
            AdaptiveDetailView(item: item, libraryName: item.libraryName)
        }
        .fullScreenPlayer(item: $playing)
        .navigationTitle(model.list.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isOwner {
                ToolbarItem(placement: .primaryAction) { editMenu }
            }
        }
        .listMessage($message)
        .task { await model.load() }
        .refreshable { await model.load() }
        .onChange(of: model.isGone) { _, gone in
            if gone { dismiss() }
        }
        .confirmationDialog(actionItem?.name ?? "", isPresented: actionBinding, titleVisibility: .visible) {
            if let item = actionItem { editActions(for: item, removeOnly: editing == .remove) }
        }
        .alert("Rename List", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { Task { if await model.rename(to: newName) { message = "Renamed" } } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete “\(model.list.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    if await model.delete() { dismiss() } else { message = "Couldn't delete the list" }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone subscribed to it loses it too. The titles stay in the library.")
        }
    }

    private var spotlightItem: BaseItemDto? {
        let items = model.contents.items
        return items.first { $0.id == spotlightId } ?? items.first
    }

    @ViewBuilder
    private var actions: some View {
        if let item = spotlightItem {
            MobileListSpotlightAction(action: .play(item)) { playing = $0 }
            MobileListSpotlightDetailsButton { opened = item }
        }
        Button {
                    Task { message = await model.toggleSubscription() }
                } label: {
                    Label(model.isSubscribed ? "Subscribed" : "Subscribe", systemImage: model.isSubscribed ? "checkmark" : "plus")
                }
                .buttonStyle(.bordered)
        Button { Task { await shuffle() } } label: { Label("Shuffle", systemImage: "shuffle") }
            .buttonStyle(.bordered)
            .disabled(model.contents.items.isEmpty)
    }

    @ViewBuilder
    private var editingHint: some View {
        if let editing {
            HStack {
                Text(editing == .reorder ? "Tap a title to move it." : "Tap a title to remove it.")
                    .font(MobileTypography.bodySmall)
                    .foregroundStyle(MobileColors.accentSecondary)
                Spacer()
                Button("Done") { self.editing = nil }
            }
        }
    }

    /// A random title; a show plays a random episode of itself.
    private func shuffle() async {
        guard let pick = model.contents.items.randomElement() else { return }
        if pick.type == .series {
            playing = try? await JellyfinClient.shared.getRandomItem(parentId: pick.id, itemTypes: [.episode])
        } else {
            playing = pick
        }
    }

    private var editMenu: some View {
        Menu {
            Button {
                newName = model.list.name
                renaming = true
            } label: { Label("Rename", systemImage: "pencil") }
            Button {
                Task {
                    let ok = await model.togglePublic()
                    message = ok ? (model.list.isPublic ? "Now public" : "Now private") : "Couldn't change it"
                }
            } label: {
                Label(model.list.isPublic ? "Make Private" : "Make Public", systemImage: model.list.isPublic ? "lock" : "person.2")
            }
            Button { editing = .reorder } label: { Label("Reorder Titles", systemImage: "arrow.up.arrow.down") }
            Button { editing = .remove } label: { Label("Remove a Title", systemImage: "minus.circle") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete List", systemImage: "trash") }
        } label: {
            Label("Edit List", systemImage: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else if model.contents.items.isEmpty {
            Text(model.failed ? "Couldn't load this list." : "Nothing on this list yet.")
                .font(MobileTypography.body)
                .foregroundStyle(MobileColors.textTertiary)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: MobileSpacing.md) {
                ForEach(model.contents.items) { item in
                    poster(item)
                }
            }
        }
    }

    @ViewBuilder
    private func poster(_ item: BaseItemDto) -> some View {
        let card = ListPosterCard(item: item, isNew: model.newIds.contains(item.id))
            .listSpotlightSelected(editing == nil && item.id == spotlightItem?.id)
        if editing != nil {
            Button { actionItem = item } label: { card }
                .buttonStyle(.plain)
        } else {
            Button { tap(item) } label: { card }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(ListSpotlightText.details, systemImage: "info.circle") { opened = item }
                    if model.isOwner { editActions(for: item, removeOnly: false) }
                }
        }
    }

    private func tap(_ item: BaseItemDto) {
        switch ListSpotlightTap.tapped(item.id, shownId: spotlightItem?.id) {
        case .select(let id):
            spotlightId = id
            selectionCount += 1
        case .open:
            opened = item
        }
    }

    private var actionBinding: Binding<Bool> {
        Binding(get: { actionItem != nil }, set: { if !$0 { actionItem = nil } })
    }

    @ViewBuilder
    private func editActions(for item: BaseItemDto, removeOnly: Bool) -> some View {
        if !removeOnly {
            if model.canMove(item, by: -2) {
                Button("Move to Start") { run { await model.move(item, by: -model.contents.items.count) } }
            }
            if model.canMove(item, by: -1) {
                Button("Move Earlier") { run { await model.move(item, by: -1) } }
            }
            if model.canMove(item, by: 1) {
                Button("Move Later") { run { await model.move(item, by: 1) } }
            }
            if model.canMove(item, by: 2) {
                Button("Move to End") { run { await model.move(item, by: model.contents.items.count) } }
            }
        }
        if removeOnly || editing == nil {
            Button("Remove from List", role: .destructive) { run { await model.remove(item) } }
        }
    }

    private func run(_ change: @escaping () async -> Bool) {
        Task {
            if !(await change()) { message = "Couldn't change the list" }
        }
    }
}

/// A list title's poster, with "NEW" for what the subscriber hasn't seen.
struct ListPosterCard: View {
    let item: BaseItemDto
    var width: CGFloat?
    let isNew: Bool

    var body: some View {
        MobileRecentlyAddedCard(
            item: item,
            width: width ?? PhoneSizing.posterWidth,
            libraryName: item.libraryName,
            isCircular: false,
            isLandscape: false,
            badgeCount: nil
        )
        .overlay(alignment: .topLeading) {
            if isNew {
                Text("NEW")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.24, green: 0.48, blue: 0.99), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
    }
}

extension View {
    /// A short message capsule at the bottom that hides itself.
    func listMessage(_ message: Binding<String?>) -> some View {
        overlay(alignment: .bottom) {
            if let text = message.wrappedValue {
                Text(text)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { message.wrappedValue = nil }
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: message.wrappedValue)
    }
}

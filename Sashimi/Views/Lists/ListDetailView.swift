import SwiftUI

/// One list: who made it, Subscribe, and its titles as a poster grid. The
/// owner also gets Edit List (rename, public/private, reorder, remove,
/// delete). Opening a subscribed list marks what it shows as seen.
struct ListDetailView: View {
    @StateObject private var model: ListDetailViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Editing { case reorder, remove }

    @State private var selected: BaseItemDto?
    @State private var playing: BaseItemDto?
    @State private var editing: Editing?
    @State private var actionItem: BaseItemDto?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @FocusState private var editMenuFocused: Bool

    private let columns = Array(repeating: GridItem(.fixed(220), spacing: 48, alignment: .top), count: 6)

    init(list: SharedList) {
        _model = StateObject(wrappedValue: ListDetailViewModel(list: list))
    }

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
        .fullScreenCover(item: $playing) { item in
            PlayerView(item: item, startFromBeginning: false)
        }
        .confirmationDialog(actionItem?.name ?? "", isPresented: actionBinding, titleVisibility: .visible) {
            if let item = actionItem { editActions(for: item) }
        }
        .alert("Rename List", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        }
        .destructiveConfirmation(
            "Delete “\(model.list.name)”?",
            isPresented: $confirmDelete,
            message: "Everyone subscribed to it loses it too. The titles stay in the library.",
            confirmTitle: "Delete"
        ) {
            Task {
                if await model.delete() {
                    ToastManager.shared.show("Deleted \(model.list.name)", type: .success)
                    dismiss()
                } else {
                    ToastManager.shared.show("Couldn't delete the list")
                }
            }
        }
        .onExitCommand {
            if editing != nil { editing = nil } else { dismiss() }
        }
        .task { await model.load() }
        .onChange(of: model.isGone) { _, gone in
            if gone {
                ToastManager.shared.show("This list is no longer available", type: .info)
                dismiss()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                if !model.isOwner, let name = model.ownerName {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 22, weight: .heavy))
                        .frame(width: 44, height: 44)
                        .background(SashimiTheme.accent, in: Circle())
                }
                Text(model.creatorLine)
                    .font(.system(size: 24))
                    .foregroundStyle(SashimiTheme.textSecondary)
            }
            Text(model.list.name)
                .font(Typography.displayMedium)
                .foregroundStyle(SashimiTheme.textPrimary)
            Text(model.summary)
                .font(.system(size: 22))
                .foregroundStyle(SashimiTheme.textTertiary)

            HStack(spacing: 30) {
                ActionButton(
                    title: model.isSubscribed ? "Subscribed" : "Subscribe",
                    icon: model.isSubscribed ? "checkmark" : "plus",
                    isPrimary: true
                ) {
                    Task {
                        let message = await model.toggleSubscription()
                        ToastManager.shared.show(message, type: message.hasPrefix("Couldn't") ? .error : .success)
                    }
                }
                ActionButton(title: "Shuffle", icon: "shuffle") { Task { await shuffle() } }
                    .disabled(model.contents.items.isEmpty)
                if model.isOwner { editMenu }
                Spacer()
            }
            .padding(.top, 10)
            .focusSection()

            if let editing {
                Text(editing == .reorder ? "Select a title to move it. Press Menu when you're done." : "Select a title to remove it. Press Menu when you're done.")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SashimiTheme.accentSecondary)
            }
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
                    ToastManager.shared.show(ok ? (model.list.isPublic ? "Now public" : "Now private") : "Couldn't change it",
                                             type: ok ? .success : .error)
                }
            } label: {
                Label(model.list.isPublic ? "Make Private" : "Make Public",
                      systemImage: model.list.isPublic ? "lock" : "person.2")
            }
            Button { editing = .reorder } label: { Label("Reorder Titles", systemImage: "arrow.left.arrow.right") }
            Button { editing = .remove } label: { Label("Remove a Title", systemImage: "minus.circle") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete List", systemImage: "trash") }
        } label: {
            Label("Edit List", systemImage: "pencil")
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(SashimiTheme.cardBackground, in: Capsule())
                .overlay(Capsule().stroke(editMenuFocused ? SashimiTheme.focus : .clear, lineWidth: 3))
                .shadow(color: editMenuFocused ? SashimiTheme.focusGlow : .clear, radius: 12)
                .scaleEffect(editMenuFocused ? 1.05 : 1.0)
                .animation(.spring(response: 0.3), value: editMenuFocused)
        }
        .focused($editMenuFocused)
        .menuStyle(.borderlessButton)
    }

    // MARK: Titles

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView()
                .focusable()
                .focusEffectDisabled()
        } else if model.contents.items.isEmpty {
            Text(model.failed ? "Couldn't load this list." : "Nothing on this list yet.")
                .font(Typography.body)
                .foregroundStyle(SashimiTheme.textTertiary)
                .focusable()
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 50) {
                ForEach(model.contents.items) { item in
                    MediaPosterButton(item: item, libraryName: item.libraryName, isNew: model.newIds.contains(item.id)) {
                        if editing != nil { actionItem = item } else { selected = item }
                    }
                }
            }
            .focusSection()
        }
    }

    private var actionBinding: Binding<Bool> {
        Binding(get: { actionItem != nil }, set: { if !$0 { actionItem = nil } })
    }

    @ViewBuilder
    private func editActions(for item: BaseItemDto) -> some View {
        if editing == .remove {
            Button("Remove from List", role: .destructive) { run { await model.remove(item) } }
        } else {
            let count = model.contents.items.count
            if model.canMove(item, by: -2) {
                Button("Move to Start") { run { await model.move(item, by: -count) } }
            }
            if model.canMove(item, by: -1) {
                Button("Move Earlier") { run { await model.move(item, by: -1) } }
            }
            if model.canMove(item, by: 1) {
                Button("Move Later") { run { await model.move(item, by: 1) } }
            }
            if model.canMove(item, by: 2) {
                Button("Move to End") { run { await model.move(item, by: count) } }
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    private func run(_ change: @escaping () async -> Bool) {
        Task {
            if !(await change()) { ToastManager.shared.show("Couldn't change the list") }
        }
    }

    private func rename() async {
        if await model.rename(to: newName) {
            ToastManager.shared.show("Renamed", type: .success)
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
}

/// A subscribed list on Home: "From Marge: Christmas Movies" with its "N new"
/// badge, the titles, and a See All card that opens the list.
struct SharedListHomeRow: View {
    let row: SubscribedListRow
    let onSelect: (BaseItemDto) -> Void
    let onOpenList: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Text(row.title)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .lineLimit(1)
                if row.newCount > 0 {
                    Text("\(row.newCount) new")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color(red: 0.24, green: 0.48, blue: 0.99), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 40)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(row.contents.items) { item in
                        MediaPosterButton(item: item, libraryName: item.libraryName, isNew: row.isNew(item.id)) {
                            onSelect(item)
                        }
                    }
                    SeeAllCard(action: onOpenList)
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 20)
            }
        }
    }
}

private struct SeeAllCard: View {
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 50))
                Text("See All")
                    .font(.system(size: 24, weight: .semibold))
            }
            .foregroundStyle(isFocused ? .white : SashimiTheme.textSecondary)
            .frame(width: 220, height: 330)
            .background(SashimiTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 4))
            .scaleEffect(isFocused ? 1.05 : 1)
            .animation(Animation.focusSpring, value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityLabel("See all")
    }
}

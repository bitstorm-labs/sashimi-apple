import SwiftUI

/// One list: who made it, Subscribe, and its titles as a poster grid. The
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

    private let columns = [GridItem(.adaptive(minimum: PhoneSizing.posterWidth, maximum: MobileSizing.posterWidth), spacing: MobileSpacing.sm, alignment: .top)]

    init(list: SharedList) {
        _model = StateObject(wrappedValue: ListDetailViewModel(list: list))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileSpacing.md) {
                header
                content
            }
            .padding(MobileSpacing.md)
        }
        .background(MobileColors.background)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.xs) {
            HStack(spacing: MobileSpacing.xs) {
                if !model.isOwner, let name = model.ownerName {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .heavy))
                        .frame(width: 26, height: 26)
                        .background(MobileColors.accent, in: Circle())
                }
                Text(model.creatorLine)
                    .font(MobileTypography.bodySmall)
                    .foregroundStyle(MobileColors.textSecondary)
            }
            Text(model.list.name)
                .font(MobileTypography.displayLarge)
                .foregroundStyle(MobileColors.textPrimary)
            Text(model.summary)
                .font(MobileTypography.caption)
                .foregroundStyle(MobileColors.textTertiary)
            Button {
                Task { message = await model.toggleSubscription() }
            } label: {
                Label(model.isSubscribed ? "Subscribed" : "Subscribe", systemImage: model.isSubscribed ? "checkmark" : "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: 320)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, MobileSpacing.xs)

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
        if editing != nil {
            Button { actionItem = item } label: { card }
                .buttonStyle(.plain)
        } else {
            NavigationLink {
                AdaptiveDetailView(item: item, libraryName: item.libraryName)
            } label: { card }
                .buttonStyle(.plain)
                .contextMenu {
                    if model.isOwner { editActions(for: item, removeOnly: false) }
                }
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

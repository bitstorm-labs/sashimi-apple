import SwiftUI

/// Add to List for one title: your lists ("Already on this list" where it
/// is) and "New List…" (name, Public switch).
struct MobileAddToListSheet: View {
    @StateObject private var model: AddToListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var newName = ""
    @State private var isPublic = false
    @State private var message: String?

    init(item: BaseItemDto) {
        _model = StateObject(wrappedValue: AddToListViewModel(item: item))
    }

    var body: some View {
        NavigationStack {
            List {
                if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Section {
                        ForEach(model.choices) { choice in
                            Button {
                                add(to: choice)
                            } label: {
                                HStack {
                                    Text(choice.list.name)
                                        .foregroundStyle(choice.alreadyOn ? MobileColors.textTertiary : MobileColors.textPrimary)
                                    Spacer()
                                    Text(choice.detail)
                                        .font(MobileTypography.caption)
                                        .foregroundStyle(MobileColors.textTertiary)
                                }
                            }
                            .disabled(model.isWorking)
                        }
                    }
                    Section {
                        if creating {
                            TextField("Name", text: $newName)
                            Toggle("Public", isOn: $isPublic)
                            Button("Create and Add") { create() }
                                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || model.isWorking)
                        } else {
                            Button {
                                creating = true
                            } label: {
                                Label("New List…", systemImage: "plus")
                            }
                        }
                    } footer: {
                        if creating {
                            Text(isPublic ? ListText.publicFootnote : "Only you can see it.")
                        }
                    }
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .listMessage($message)
        }
        .presentationDetents([.medium, .large])
        .task { await model.load() }
    }

    private func add(to choice: AddToListViewModel.Choice) {
        guard !choice.alreadyOn else {
            message = "Already on \(choice.list.name)"
            return
        }
        Task {
            let result = await model.add(to: choice.list)
            message = result
            if result.hasPrefix("Added") {
                try? await Task.sleep(for: .seconds(0.8))
                dismiss()
            }
        }
    }

    private func create() {
        Task {
            let result = await model.create(name: newName, isPublic: isPublic)
            message = result
            if result.hasPrefix("Added") {
                try? await Task.sleep(for: .seconds(0.8))
                dismiss()
            }
        }
    }
}

/// A subscribed list on Home: "From Marge: Christmas Movies" with its "N new"
/// badge. The header opens the list.
struct MobileSharedListRow<Destination: View>: View {
    let row: SubscribedListRow
    let cardWidth: CGFloat
    let destination: (BaseItemDto) -> Destination

    var body: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.sm) {
            NavigationLink {
                MobileListDetailView(list: row.list)
            } label: {
                HStack(spacing: MobileSpacing.xs) {
                    Text(row.title)
                        .font(MobileTypography.headline)
                        .foregroundStyle(MobileColors.textPrimary)
                        .lineLimit(1)
                    if row.newCount > 0 {
                        Text("\(row.newCount) new")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color(red: 0.24, green: 0.48, blue: 0.99), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(MobileColors.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, MobileSpacing.md)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: MobileSpacing.sm) {
                    ForEach(row.contents.items) { item in
                        NavigationLink {
                            destination(item)
                        } label: {
                            ListPosterCard(item: item, width: cardWidth, isNew: row.isNew(item.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, MobileSpacing.md)
            }
        }
    }
}

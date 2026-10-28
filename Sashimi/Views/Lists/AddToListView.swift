import SwiftUI

/// Add to List, over a detail page: your lists ("Already on this list" where
/// the title is), then "New List…". One cover whose content changes, as Add to
/// Channel does, so Menu steps back and focus always has a row to land on.
struct AddToListView: View {
    @StateObject private var model: AddToListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false

    init(item: BaseItemDto) {
        _model = StateObject(wrappedValue: AddToListViewModel(item: item))
    }

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()
            if creating {
                NewListForm(
                    title: "New List",
                    subtitle: "Starts with \(model.item.name)",
                    confirmTitle: "Create and Add",
                    isWorking: model.isWorking
                ) { name, isPublic in
                    Task {
                        let message = await model.create(name: name, isPublic: isPublic)
                        ToastManager.shared.show(message, type: message.hasPrefix("Added") ? .success : .error)
                        if message.hasPrefix("Added") { dismiss() }
                    }
                } onCancel: {
                    creating = false
                }
            } else {
                choices
            }
        }
        .onExitCommand {
            if creating { creating = false } else { dismiss() }
        }
        .task { await model.load() }
    }

    private var choices: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ChannelScreenHeader(title: model.title)
                    .padding(.bottom, 18)

                if model.isLoading {
                    ProgressView()
                        .padding(.top, 40)
                        .focusable()
                        .focusEffectDisabled()
                } else {
                    ForEach(model.choices) { choice in
                        ChannelChoiceRow(
                            logoKey: nil,
                            showsLogo: false,
                            title: choice.list.name,
                            detail: choice.detail,
                            trailing: choice.alreadyOn ? .checkmark : .none,
                            isEnabled: !model.isWorking
                        ) {
                            add(to: choice)
                        }
                    }

                    ChannelChoiceRow(
                        logoKey: nil,
                        title: "New List…",
                        systemImage: "plus",
                        isEnabled: !model.isWorking
                    ) { creating = true }
                    .padding(.top, 10)
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 120)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity)
        }
        .scrollClipDisabled()
    }

    private func add(to choice: AddToListViewModel.Choice) {
        guard !choice.alreadyOn else {
            ToastManager.shared.show("Already on \(choice.list.name)", type: .info)
            return
        }
        Task {
            let message = await model.add(to: choice.list)
            ToastManager.shared.show(message, type: message.hasPrefix("Added") ? .success : .info)
            dismiss()
        }
    }
}

/// Name and Public switch for a new list.
struct NewListForm: View {
    let title: String
    var subtitle: String?
    let confirmTitle: String
    let isWorking: Bool
    let onCreate: (String, Bool) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var isPublic = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                ChannelScreenHeader(title: title, subtitle: subtitle)

                VStack(alignment: .leading, spacing: 12) {
                    Text("NAME")
                        .font(.system(size: 20, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(SashimiTheme.textTertiary)
                    TextField("List name", text: $name)
                        .font(.system(size: 28))
                        .frame(maxWidth: 900)
                        .focused($nameFocused)
                }
                .focusSection()

                VStack(alignment: .leading, spacing: 10) {
                    ChannelChoiceRow(
                        logoKey: nil,
                        title: "Public",
                        detail: isPublic ? ListText.publicFootnote : "Only you can see it.",
                        systemImage: isPublic ? "person.2.fill" : "lock.fill",
                        trailing: isPublic ? .checkmark : .none
                    ) { isPublic.toggle() }
                }
                .frame(maxWidth: 900)

                HStack(spacing: 30) {
                    ActionButton(title: "Cancel", icon: "xmark") { onCancel() }
                    ActionButton(title: isWorking ? "Creating…" : confirmTitle, icon: "plus", isPrimary: true) {
                        onCreate(name, isPublic)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                    Spacer()
                }
                .focusSection()
            }
            .padding(.horizontal, 120)
            .padding(.vertical, 80)
        }
        .scrollClipDisabled()
        .task { nameFocused = true }
    }
}

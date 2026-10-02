import SwiftUI

/// New Channel: a name, a logo, and (from a detail page) the title it starts
/// with. Dayparts, seasons and rules stay in the dashboard.
struct MobileNewChannelForm: View {
    @ObservedObject var model: ChannelManagementViewModel
    let seed: ChannelTarget?
    let onFinish: (ManagedChannel?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var logo: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        Form {
            Section("Name") {
                TextField("Channel name", text: $name)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit(create)
            }

            Section("Logo") {
                MobileChannelLogoGrid(keys: model.logoKeys, selected: logo) { logo = $0 }
            }

            if let seed {
                Section {
                    LabeledContent("Starts with", value: seed.title)
                } footer: {
                    Text("Dayparts, seasons and genre rules can be added later in the Jellyfin dashboard.")
                }
            }
        }
        .channelScreenStyle()
        .navigationTitle("New Channel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    onFinish(nil)
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create", action: create)
                    .disabled(ChannelManagementViewModel.validatedName(name) == nil || model.isWorking)
            }
        }
        .channelErrorAlert(model)
        .task {
            await model.loadLogos()
            nameFocused = true
        }
    }

    private func create() {
        guard ChannelManagementViewModel.validatedName(name) != nil else { return }
        Task {
            if let created = await model.createChannel(name: name, logo: logo, seedItemId: seed?.itemId) {
                onFinish(created)
                dismiss()
            }
        }
    }
}

/// "No logo" then every logo the plugin ships, as tappable tiles.
struct MobileChannelLogoGrid: View {
    let keys: [String]
    let selected: String?
    var isEnabled = true
    let onSelect: (String?) -> Void

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            tile(nil)
            ForEach(keys, id: \.self) { tile($0) }
        }
        .padding(.vertical, 6)
        .disabled(!isEnabled)
    }

    private func tile(_ key: String?) -> some View {
        let isSelected = selected == key
        let label = key.map(ChannelLogoKeyView.displayName(for:)) ?? "No logo"
        return Button { onSelect(key) } label: {
            VStack(spacing: 6) {
                if let key {
                    ChannelLogoKeyView(key: key, name: key, size: 44)
                } else {
                    Image(systemName: "nosign")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 44, height: 44)
                }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? MobileColors.accent.opacity(0.25) : Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(MobileColors.accent, lineWidth: isSelected ? 2 : 0)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

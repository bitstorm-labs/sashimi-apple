import SwiftUI

/// New Channel: a name, a logo, and (from a detail page) the title it starts
/// with. Day parts, seasons and rules are the dashboard's job; the server
/// gives a new channel one all-day daypart named after it.
struct NewChannelForm: View {
    @ObservedObject var model: ChannelManagementViewModel
    /// The title the channel starts with, when opened from a detail page.
    let seed: ChannelTarget?
    let onFinish: (ManagedChannel?) -> Void

    @State private var name = ""
    @State private var logo: String?
    @FocusState private var nameFocused: Bool

    private var canCreate: Bool {
        ChannelManagementViewModel.validatedName(name) != nil && !model.isWorking
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                ChannelScreenHeader(
                    title: "New Channel",
                    subtitle: "Dayparts, seasons and genre rules can be added later in the Jellyfin dashboard."
                )

                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("Name")
                    TextField("Channel name", text: $name)
                        .font(.system(size: 28))
                        .frame(maxWidth: 900)
                        .focused($nameFocused)
                }
                .focusSection()

                VStack(alignment: .leading, spacing: 16) {
                    sectionLabel("Logo")
                    if model.logoKeys.isEmpty {
                        Text("No logos available from the server.")
                            .font(.system(size: 22))
                            .foregroundStyle(SashimiTheme.textTertiary)
                    }
                    ChannelLogoGrid(keys: model.logoKeys, selected: logo) { logo = $0 }
                }

                if let seed {
                    HStack(spacing: 12) {
                        Text("Starts with:")
                            .foregroundStyle(SashimiTheme.textSecondary)
                        Text(seed.title)
                            .foregroundStyle(SashimiTheme.textPrimary)
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 26))
                }

                HStack(spacing: 30) {
                    ActionButton(title: "Cancel", icon: "xmark") { onFinish(nil) }
                    ActionButton(title: model.isWorking ? "Creating…" : "Create", icon: "plus", isPrimary: true) {
                        create()
                    }
                    .disabled(!canCreate)
                    Spacer()
                }
                .focusSection()
            }
            .padding(.horizontal, 120)
            .padding(.vertical, 80)
        }
        .scrollClipDisabled()
        .task {
            await model.loadLogos()
            // Name first: it is the one thing a channel cannot be made without.
            nameFocused = true
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 20, weight: .bold))
            .tracking(1.4)
            .foregroundStyle(SashimiTheme.textTertiary)
    }

    private func create() {
        Task {
            if let created = await model.createChannel(name: name, logo: logo, seedItemId: seed?.itemId) {
                ToastManager.shared.show("Created \(created.name)", type: .success)
                onFinish(created)
            }
        }
    }
}

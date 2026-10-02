import SwiftUI

/// Where focus goes when the Manage Channels cover changes screens.
private enum ManageFocus: Hashable {
    case channel(String)
    case newChannel
    case name
}

/// Manage Channels, from the guide: every channel, then one channel's name,
/// logo, hand-added titles (each removable) and the rules that also feed it
/// (read-only — those live in the dashboard), and Delete.
///
/// Like Add to Channel, one cover whose content changes, so Menu steps back a
/// level and focus returns to the row the viewer left.
struct ManageChannelsView: View {
    @StateObject private var model = ChannelManagementViewModel()
    @Environment(\.dismiss) private var dismiss

    private enum Screen: Equatable {
        case list
        case channel(String)
        case newChannel
    }

    private struct Removal: Identifiable {
        let channel: ManagedChannel
        let item: ManagedItem
        let daypartIndex: Int?
        var id: String { "\(channel.id)-\(item.id)-\(daypartIndex ?? -1)" }
    }

    @State private var screen: Screen = .list
    @State private var draftName = ""
    @State private var pendingRemoval: Removal?
    @State private var confirmingDelete = false
    @FocusState private var focus: ManageFocus?

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()

            switch screen {
            case .list:
                channelList
            case .channel(let id):
                if let channel = model.channel(id: id) {
                    ChannelDetail(
                        model: model,
                        channel: channel,
                        draftName: $draftName,
                        nameFocus: $focus,
                        onRemove: requestRemoval,
                        onDelete: { confirmingDelete = true }
                    )
                } else {
                    channelList
                }
            case .newChannel:
                NewChannelForm(model: model, seed: nil) { created in
                    if let created {
                        open(created)
                    } else {
                        show(.list, focusing: .newChannel)
                    }
                }
            }
        }
        .onExitCommand(perform: back)
        .task { await model.loadChannels() }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { removal in
            Button("Remove", role: .destructive) { remove(removal) }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { removal in
            Text("\(removal.item.name) is the last title on \(removal.channel.name) and nothing else feeds it, so the channel will go off air.")
        }
        .confirmationDialog(
            "Delete \(currentChannel?.name ?? "this channel")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Channel", role: .destructive) { deleteCurrent() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The channel and its guide are removed from every device. The titles stay in your library.")
        }
        .alert("Couldn't update the channel", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - List

    private var channelList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ChannelScreenHeader(
                    title: "Manage Channels",
                    subtitle: "Name, logo and the titles you added. Dayparts, seasons and rules live in the Jellyfin dashboard."
                )
                .padding(.bottom, 30)

                if model.channels.isEmpty && (model.isLoading || model.loadFailed) {
                    ChannelLoadState(isLoading: model.isLoading, message: model.errorMessage) {
                        Task { await model.loadChannels() }
                    }
                } else {
                    ForEach(model.channels) { channel in
                        ChannelChoiceRow(
                            logoKey: channel.logo,
                            title: channel.name,
                            detail: channel.managementSummary,
                            trailing: .chevron
                        ) { open(channel) }
                        .focused($focus, equals: .channel(channel.id))
                    }

                    ChannelChoiceRow(logoKey: nil, title: "New Channel", systemImage: "plus") {
                        screen = .newChannel
                    }
                    .focused($focus, equals: .newChannel)
                    .padding(.top, 10)
                }
            }
            .focusSection()
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 120)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity)
        }
        .scrollClipDisabled()
    }

    // MARK: - Actions

    private var currentChannel: ManagedChannel? {
        if case .channel(let id) = screen { return model.channel(id: id) }
        return nil
    }

    private func open(_ channel: ManagedChannel) {
        draftName = channel.name
        show(.channel(channel.id), focusing: .name)
    }

    private func back() {
        switch screen {
        case .list:
            dismiss()
        case .channel(let id):
            commitName()
            show(.list, focusing: .channel(id))
        case .newChannel:
            show(.list, focusing: .newChannel)
        }
    }

    private func show(_ next: Screen, focusing target: ManageFocus?) {
        screen = next
        DispatchQueue.main.async { focus = target }
    }

    /// A name edited and left without pressing Done still counts.
    private func commitName() {
        guard let channel = currentChannel, draftName != channel.name else { return }
        let name = draftName
        Task { await model.rename(channelId: channel.id, to: name) }
    }

    private func requestRemoval(_ channel: ManagedChannel, _ item: ManagedItem, _ daypartIndex: Int?) {
        let removal = Removal(channel: channel, item: item, daypartIndex: daypartIndex)
        if channel.removingTakesOffAir(itemId: item.id, daypartIndex: daypartIndex) {
            pendingRemoval = removal
        } else {
            remove(removal)
        }
    }

    private func remove(_ removal: Removal) {
        pendingRemoval = nil
        Task {
            await model.removeItem(removal.item.id, from: removal.channel.id, daypartIndex: removal.daypartIndex)
        }
    }

    private func deleteCurrent() {
        guard let channel = currentChannel else { return }
        Task {
            if await model.deleteChannel(channelId: channel.id) {
                show(.list, focusing: model.channels.first.map { .channel($0.id) } ?? .newChannel)
            }
        }
    }

    private var removalTitle: String {
        "Take \(pendingRemoval?.channel.name ?? "this channel") off air?"
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil && !model.loadFailed }, set: { if !$0 { model.errorMessage = nil } })
    }
}

/// One channel: name, logo, the titles added by hand, rules, Delete.
private struct ChannelDetail: View {
    @ObservedObject var model: ChannelManagementViewModel
    let channel: ManagedChannel
    @Binding var draftName: String
    var nameFocus: FocusState<ManageFocus?>.Binding
    let onRemove: (ManagedChannel, ManagedItem, Int?) -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                HStack(spacing: 24) {
                    ChannelLogoKeyView(key: channel.logo, name: channel.name, size: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(channel.name)
                            .font(.system(size: 48, weight: .bold))
                            .foregroundStyle(SashimiTheme.textPrimary)
                        if let number = channel.number {
                            Text("Channel \(number)")
                                .font(.system(size: 22))
                                .foregroundStyle(SashimiTheme.textSecondary)
                        }
                    }
                }

                section("Name") {
                    TextField("Channel name", text: $draftName)
                        .font(.system(size: 28))
                        .frame(maxWidth: 900)
                        .focused(nameFocus, equals: .name)
                        .onSubmit {
                            let name = draftName
                            Task { await model.rename(channelId: channel.id, to: name) }
                        }
                }
                .focusSection()

                section("Logo") {
                    ChannelLogoGrid(keys: model.logoKeys, selected: channel.logo, isEnabled: !model.isWorking) { key in
                        Task { await model.setLogo(channelId: channel.id, logo: key) }
                    }
                }

                section("Shows added here") {
                    VStack(alignment: .leading, spacing: 30) {
                        ForEach(channel.dayparts) { daypart in
                            daypartBlock(daypart)
                        }
                    }
                }

                ActionButton(title: "Delete Channel", icon: "trash", action: onDelete)
                    .disabled(model.isWorking)
                    .focusSection()
            }
            .frame(maxWidth: 1300, alignment: .leading)
            .padding(.horizontal, 120)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity)
        }
        .scrollClipDisabled()
        .task { await model.loadLogos() }
    }

    @ViewBuilder
    private func daypartBlock(_ daypart: ManagedDaypart) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if channel.isScheduled {
                HStack(spacing: 12) {
                    Text(daypart.name)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(SashimiTheme.textPrimary)
                    Text(daypart.scheduleLine)
                        .font(.system(size: 20))
                        .foregroundStyle(SashimiTheme.textTertiary)
                }
            }

            if daypart.addedItems.isEmpty {
                Text("Nothing added here yet.")
                    .font(.system(size: 22))
                    .foregroundStyle(SashimiTheme.textTertiary)
            }

            ForEach(daypart.addedItems) { item in
                ChannelChoiceRow(
                    logoKey: nil,
                    showsLogo: false,
                    title: item.name,
                    detail: item.detailLine,
                    trailing: .remove,
                    isEnabled: !model.isWorking
                ) { onRemove(channel, item, daypart.index) }
                .accessibilityLabel("Remove \(item.name)")
            }

            if let rule = daypart.ruleSentence {
                Text(rule)
                    .font(.system(size: 21))
                    .foregroundStyle(SashimiTheme.textSecondary)
                    .padding(.top, 4)
            }
        }
        .focusSection()
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.uppercased())
                .font(.system(size: 20, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(SashimiTheme.textTertiary)
            content()
        }
    }
}

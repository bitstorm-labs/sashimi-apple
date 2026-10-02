import SwiftUI

/// Manage Channels on iPhone and iPad, from the guide: the channel list, then
/// one channel's name, logo, hand-added titles (each removable), the rules
/// that also feed it (read-only), and Delete.
struct MobileManageChannelsView: View {
    @StateObject private var model = ChannelManagementViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.channels.isEmpty && (model.isLoading || model.loadFailed) {
                    MobileChannelLoadState(isLoading: model.isLoading, message: model.errorMessage) {
                        Task { await model.loadChannels() }
                    }
                } else {
                    Section {
                        ForEach(model.channels) { channel in
                            NavigationLink {
                                MobileChannelDetailView(model: model, channelId: channel.id)
                            } label: {
                                MobileChannelLabel(
                                    logoKey: channel.logo,
                                    title: channel.name,
                                    detail: channel.managementSummary
                                )
                            }
                        }
                    } footer: {
                        Text("Dayparts, seasons and genre rules are edited in the Jellyfin dashboard.")
                    }

                    Section {
                        NavigationLink {
                            MobileNewChannelForm(model: model, seed: nil) { _ in }
                        } label: {
                            Label("New Channel", systemImage: "plus")
                                .foregroundStyle(MobileColors.accent)
                        }
                    }
                }
            }
            .navigationTitle("Manage Channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await model.loadChannels() }
        }
        .task { await model.loadChannels() }
        .channelErrorAlert(model)
    }
}

/// One channel. Edits go to the server as they are made; there is no Save.
struct MobileChannelDetailView: View {
    @ObservedObject var model: ChannelManagementViewModel
    let channelId: String

    @Environment(\.dismiss) private var dismiss
    @State private var draftName = ""
    @State private var pendingRemoval: Removal?
    @State private var confirmingDelete = false

    private struct Removal: Identifiable {
        let item: ManagedItem
        let daypartIndex: Int?
        var id: String { "\(item.id)-\(daypartIndex ?? -1)" }
    }

    private var channel: ManagedChannel? { model.channel(id: channelId) }

    var body: some View {
        Form {
            if let channel {
                Section("Name") {
                    TextField("Channel name", text: $draftName)
                        .submitLabel(.done)
                        .onSubmit(commitName)
                }

                Section("Logo") {
                    MobileChannelLogoGrid(keys: model.logoKeys, selected: channel.logo, isEnabled: !model.isWorking) { key in
                        Task { await model.setLogo(channelId: channel.id, logo: key) }
                    }
                }

                ForEach(channel.dayparts) { daypart in
                    Section {
                        if daypart.addedItems.isEmpty {
                            Text("Nothing added here yet.")
                                .foregroundStyle(Color.secondary.opacity(0.7))
                        }
                        ForEach(daypart.addedItems) { item in
                            itemRow(item, channel: channel, daypartIndex: daypart.index)
                        }
                    } header: {
                        if channel.isScheduled {
                            Text("\(daypart.name) · \(daypart.scheduleLine)")
                        } else {
                            Text("Shows added here")
                        }
                    } footer: {
                        if let rule = daypart.ruleSentence {
                            Text(rule)
                        }
                    }
                }

                Section {
                    Button("Delete Channel", role: .destructive) { confirmingDelete = true }
                        .disabled(model.isWorking)
                }
            }
        }
        .navigationTitle(channel?.name ?? "Channel")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            draftName = channel?.name ?? ""
            await model.loadLogos()
        }
        // Leaving with an edited name that was never submitted still saves it.
        .onDisappear(perform: commitName)
        .confirmationDialog(
            "Take \(channel?.name ?? "this channel") off air?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { removal in
            Button("Remove", role: .destructive) { remove(removal) }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text("\(removal.item.name) is the last title on \(channel?.name ?? "the channel") and nothing else feeds it, so the channel will go off air.")
        }
        .confirmationDialog("Delete \(channel?.name ?? "this channel")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Channel", role: .destructive) {
                Task {
                    if await model.deleteChannel(channelId: channelId) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The channel and its guide are removed from every device. The titles stay in your library.")
        }
    }

    private func itemRow(_ item: ManagedItem, channel: ManagedChannel, daypartIndex: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                if !item.detailLine.isEmpty {
                    Text(item.detailLine)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
            Spacer()
            Button {
                requestRemoval(item, channel: channel, daypartIndex: daypartIndex)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .disabled(model.isWorking)
            .accessibilityLabel("Remove \(item.name)")
        }
    }

    private func requestRemoval(_ item: ManagedItem, channel: ManagedChannel, daypartIndex: Int) {
        let removal = Removal(item: item, daypartIndex: daypartIndex)
        if channel.removingTakesOffAir(itemId: item.id, daypartIndex: daypartIndex) {
            pendingRemoval = removal
        } else {
            remove(removal)
        }
    }

    private func remove(_ removal: Removal) {
        pendingRemoval = nil
        Task { await model.removeItem(removal.item.id, from: channelId, daypartIndex: removal.daypartIndex) }
    }

    private func commitName() {
        guard let channel, draftName != channel.name,
              ChannelManagementViewModel.validatedName(draftName) != nil else { return }
        let name = draftName
        Task { await model.rename(channelId: channel.id, to: name) }
    }
}

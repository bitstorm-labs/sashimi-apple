import SwiftUI

/// Add to Channel on iPhone and iPad: every channel with a checkmark where the
/// title already airs. Tapping an Added channel removes the title; tapping an
/// unchecked one adds it; a rule's checkmark is dimmed and inert. Scheduled
/// channels push a pick of their dayparts. "New Channel…" sits at the bottom.
struct MobileAddToChannelSheet: View {
    let target: ChannelTarget

    @StateObject private var model = ChannelManagementViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: ChannelMenuOption?

    var body: some View {
        NavigationStack {
            List {
                if model.channels.isEmpty && (model.isLoading || model.loadFailed) {
                    MobileChannelLoadState(isLoading: model.isLoading, message: model.errorMessage) {
                        Task { await model.loadMenu(itemId: target.itemId) }
                    }
                } else {
                    Section {
                        ForEach(model.menuEntries) { entry in
                            if let option = entry.single {
                                optionRow(option, logoKey: entry.channel.logo, showsLogo: true)
                            } else {
                                NavigationLink {
                                    daypartList(channelId: entry.id)
                                } label: {
                                    MobileChannelLabel(
                                        logoKey: entry.channel.logo,
                                        title: entry.channel.name,
                                        detail: entry.scheduledSummary
                                    )
                                }
                            }
                        }
                    } header: {
                        Text(target.title)
                    }

                    Section {
                        NavigationLink {
                            MobileNewChannelForm(model: model, seed: target) { created in
                                if created != nil { dismiss() }
                            }
                        } label: {
                            Label("New Channel…", systemImage: "plus")
                                .foregroundStyle(MobileColors.accent)
                        }
                    }
                }
            }
            .disabled(model.isWorking)
            .navigationTitle("Add to Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await model.loadMenu(itemId: target.itemId) }
        .channelRemovalConfirmation($pendingRemoval, itemTitle: target.title, model: model) { option in
            Task { await model.apply(option, itemId: target.itemId) }
        }
        .channelErrorAlert(model)
    }

    private func daypartList(channelId: String) -> some View {
        let entry = model.menuEntries.first { $0.id == channelId }
        return List {
            Section {
                ForEach(entry?.dayparts ?? []) { option in
                    let daypart = entry?.channel.dayparts.first { $0.index == option.daypartIndex }
                    optionRow(option, logoKey: nil, showsLogo: false, detail: daypart.map(\.scheduleLine))
                }
            } footer: {
                Text("Which part of the day should \(target.title) air in?")
            }
        }
        .disabled(model.isWorking)
        .navigationTitle(entry?.channel.name ?? "Channel")
    }

    private func optionRow(_ option: ChannelMenuOption, logoKey: String?, showsLogo: Bool, detail: String? = nil) -> some View {
        Button {
            if model.removalTakesOffAir(option, itemId: target.itemId) {
                pendingRemoval = option
            } else {
                Task { await model.apply(option, itemId: target.itemId) }
            }
        } label: {
            HStack {
                MobileChannelLabel(logoKey: logoKey, title: option.title, detail: detail, showsLogo: showsLogo)
                Spacer()
                if let via = option.viaLabel {
                    Text(via)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
                if option.isChecked {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(option.isEnabled ? MobileColors.accent : Color.secondary.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.isEnabled)
    }
}

/// Logo, name and a detail line — the label every management row shares.
struct MobileChannelLabel: View {
    let logoKey: String?
    let title: String
    var detail: String?
    var showsLogo = true

    var body: some View {
        HStack(spacing: 12) {
            if showsLogo {
                ChannelLogoKeyView(key: logoKey, name: title, size: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Color.primary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }
}

struct MobileChannelLoadState: View {
    let isLoading: Bool
    let message: String?
    let retry: () -> Void

    var body: some View {
        if isLoading {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .listRowBackground(Color.clear)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(message ?? "Couldn't load channels.")
                    .foregroundStyle(Color.secondary)
                Button("Try Again", action: retry)
            }
        }
    }
}

extension View {
    /// Ask before removing the last title from a channel nothing else feeds.
    func channelRemovalConfirmation(
        _ pending: Binding<ChannelMenuOption?>,
        itemTitle: String,
        model: ChannelManagementViewModel,
        perform: @escaping (ChannelMenuOption) -> Void
    ) -> some View {
        let channelName = pending.wrappedValue.flatMap { model.channel(id: $0.channelId)?.name } ?? "this channel"
        return confirmationDialog(
            "Take \(channelName) off air?",
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { option in
            Button("Remove", role: .destructive) { perform(option) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("\(itemTitle) is the last title on \(channelName) and nothing else feeds it, so the channel will go off air.")
        }
    }

    /// A failed change, in the server's words where it gave any.
    func channelErrorAlert(_ model: ChannelManagementViewModel) -> some View {
        alert(
            "Couldn't update the channel",
            isPresented: Binding(
                get: { model.errorMessage != nil && !model.loadFailed },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

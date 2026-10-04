import SwiftUI

/// Add to Channel, over a detail page: every channel with a checkmark where
/// the title already airs. Added toggles off, unchecked toggles on, a rule's
/// checkmark is shown but cannot be changed here. A scheduled channel opens a
/// pick of its dayparts. "New Channel…" closes the list.
///
/// One cover whose content changes (channels → dayparts → new channel)
/// rather than covers stacked on covers: Menu steps back one level, and
/// focus always has a row to land on.
struct AddToChannelView: View {
    let target: ChannelTarget

    @StateObject private var model = ChannelManagementViewModel()
    @Environment(\.dismiss) private var dismiss

    private enum Screen: Equatable {
        case channels
        case dayparts(String)
        case newChannel
    }

    private enum Focus: Hashable {
        case channel(String)
        case newChannel
        case daypart(String)
    }

    @State private var screen: Screen = .channels
    @State private var pendingRemoval: ChannelMenuOption?
    @FocusState private var focus: Focus?

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()

            switch screen {
            case .newChannel:
                NewChannelForm(model: model, seed: target) { created in
                    if created != nil {
                        dismiss()
                    } else {
                        show(.channels, focusing: .newChannel)
                    }
                }
            case .channels, .dayparts:
                list
            }
        }
        .onExitCommand(perform: back)
        .task { await model.loadMenu(itemId: target.itemId) }
        // Opens with Cancel focused: a stray press of the remote must not
        // take a channel off air.
        .destructiveConfirmation(
            "Take \(channelName(pendingRemoval)) off air?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            message: "\(target.title) is the last title on \(channelName(pendingRemoval)) and nothing else feeds it, so the channel will go off air.",
            confirmTitle: "Remove"
        ) {
            if let option = pendingRemoval { apply(option, confirmed: true) }
        }
        .alert("Couldn't update the channel", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                    .padding(.bottom, 18)

                if model.channels.isEmpty && (model.isLoading || model.loadFailed) {
                    ChannelLoadState(isLoading: model.isLoading, message: model.errorMessage) {
                        Task { await model.loadMenu(itemId: target.itemId) }
                    }
                } else if case .dayparts(let channelId) = screen,
                          let entry = model.menuEntries.first(where: { $0.id == channelId }) {
                    daypartRows(entry)
                } else {
                    channelRows
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 120)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity)
        }
        .scrollClipDisabled()
    }

    private var header: some View {
        if case .dayparts(let channelId) = screen, let channel = model.channel(id: channelId) {
            return ChannelScreenHeader(
                title: channel.name,
                subtitle: "Which part of the day should \(target.title) air in?"
            )
        }
        return ChannelScreenHeader(title: "Add to Channel", subtitle: target.title)
    }

    private var channelRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.menuEntries) { entry in
                if let option = entry.single {
                    ChannelChoiceRow(
                        logoKey: entry.channel.logo,
                        title: entry.channel.name,
                        trailing: trailing(for: option),
                        isEnabled: option.isEnabled && !model.isWorking
                    ) { apply(option) }
                    .focused($focus, equals: .channel(entry.id))
                } else {
                    ChannelChoiceRow(
                        logoKey: entry.channel.logo,
                        title: entry.channel.name,
                        detail: entry.scheduledSummary,
                        trailing: .chevron,
                        isEnabled: !model.isWorking
                    ) { show(.dayparts(entry.id), focusing: entry.dayparts.first.map { .daypart($0.id) }) }
                    .focused($focus, equals: .channel(entry.id))
                }
            }

            ChannelChoiceRow(
                logoKey: nil,
                title: "New Channel…",
                detail: "Starts with \(target.title)",
                systemImage: "plus",
                isEnabled: !model.isWorking
            ) { screen = .newChannel }
            .focused($focus, equals: .newChannel)
            .padding(.top, 10)
        }
        .focusSection()
    }

    private func daypartRows(_ entry: ChannelMenuEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(entry.dayparts) { option in
                let daypart = entry.channel.dayparts.first { $0.index == option.daypartIndex }
                ChannelChoiceRow(
                    logoKey: nil,
                    showsLogo: false,
                    title: option.title,
                    detail: daypart?.scheduleLine,
                    trailing: trailing(for: option),
                    isEnabled: option.isEnabled && !model.isWorking
                ) { apply(option) }
                .focused($focus, equals: .daypart(option.id))
            }
        }
        .focusSection()
    }

    // MARK: - Actions

    private func apply(_ option: ChannelMenuOption, confirmed: Bool = false) {
        if !confirmed, model.removalTakesOffAir(option, itemId: target.itemId) {
            pendingRemoval = option
            return
        }
        pendingRemoval = nil
        Task { await model.apply(option, itemId: target.itemId) }
    }

    private func back() {
        switch screen {
        case .channels:
            dismiss()
        case .dayparts(let channelId):
            show(.channels, focusing: .channel(channelId))
        case .newChannel:
            show(.channels, focusing: .newChannel)
        }
    }

    /// Swap the content and put focus on the row the viewer came from (or
    /// is going to). Deferred a turn so the row exists when focus moves.
    private func show(_ next: Screen, focusing target: Focus?) {
        screen = next
        DispatchQueue.main.async { focus = target }
    }

    // MARK: - Labels

    private func trailing(for option: ChannelMenuOption) -> ChannelChoiceRow.Trailing {
        switch option.state {
        case .added: return .checkmark
        case .viaRule: return .viaRule(option.viaLabel ?? "")
        case .none: return .none
        }
    }

    private func channelName(_ option: ChannelMenuOption?) -> String {
        option.flatMap { model.channel(id: $0.channelId)?.name } ?? "this channel"
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil && !model.loadFailed }, set: { if !$0 { model.errorMessage = nil } })
    }
}

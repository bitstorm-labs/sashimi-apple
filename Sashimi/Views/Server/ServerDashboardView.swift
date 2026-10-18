import SwiftUI

/// The admin Server dashboard on tvOS, layout A: one page with Now playing on
/// top and Activity + Health side by side below. Reached from Settings, and
/// only offered to the server's administrators.
struct ServerDashboardView: View {
    @StateObject private var model: ServerDashboardViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected: DashboardSession?
    /// Each state swap removes whatever held focus (the loading message, say);
    /// re-resolving inside this scope lands on the first stream instead of
    /// letting tvOS fall back to the rail.
    @Namespace private var focusNamespace
    @Environment(\.resetFocus) private var resetFocus

    /// - Parameter model: injected by tests; the screen makes its own otherwise.
    init(model: ServerDashboardViewModel? = nil) {
        _model = StateObject(wrappedValue: model ?? ServerDashboardViewModel())
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 32, alignment: .top), count: 3)

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()

            switch model.state {
            case .loading:
                ServerFocusableMessage(icon: "server.rack", title: "Asking the server…")
                    .prefersDefaultFocus(in: focusNamespace)
                    .frame(maxWidth: 900)
            case .denied:
                ServerFocusableMessage(
                    icon: "lock",
                    title: "Administrators only",
                    message: "This server only shows this to its administrators."
                )
                .prefersDefaultFocus(in: focusNamespace)
                .frame(maxWidth: 900)
            case .failed:
                ErrorStateView(
                    title: "Can't reach the server",
                    message: "Trying again every few seconds.",
                    retryAction: { Task { await model.refreshAll() } }
                )
            case .loaded:
                dashboard
            }
        }
        .focusScope(focusNamespace)
        .onChange(of: model.state) { _, _ in
            resetFocus(in: focusNamespace)
        }
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
        .onChange(of: scenePhase) { _, phase in
            model.setSceneActive(phase == .active)
        }
        .sheet(item: $selected) { session in
            ServerStreamSheet(session: session, model: model)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(model.actionError ?? "") }
        )
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                header
                nowPlaying
                HStack(alignment: .top, spacing: 32) {
                    ServerDashboardPanel(title: "Recent activity") {
                        if model.activity.isEmpty {
                            Text("Nothing yet").font(Typography.bodySmall).foregroundStyle(SashimiTheme.textTertiary)
                        }
                        ForEach(model.activity) { row in
                            ServerDotRow(tone: row.tone, text: row.text, value: row.when)
                        }
                    }
                    ServerDashboardPanel(title: "Health") {
                        if model.health.isEmpty {
                            Text("Nothing to report").font(Typography.bodySmall).foregroundStyle(SashimiTheme.textTertiary)
                        }
                        ForEach(model.health) { row in
                            ServerDotRow(tone: row.tone, text: row.title, value: row.value)
                        }
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 50)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text("Server")
                    .font(Typography.displayMedium)
                    .foregroundStyle(SashimiTheme.textPrimary)
                Text(model.serverLine)
                    .font(Typography.titleSmall)
                    .foregroundStyle(SashimiTheme.textSecondary)
            }
            Spacer()
            HStack(spacing: 20) {
                ServerCountPill(value: "\(model.sessions.count)", label: "streaming", tint: SashimiTheme.accent)
                ServerCountPill(value: "\(model.convertingCount)", label: "converting", tint: SashimiTheme.accentSecondary)
                ServerCountPill(value: ServerDashboardLogic.formatBitrate(model.totalBitrate), label: "out")
            }
        }
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Now playing")
                .font(Typography.title)
                .foregroundStyle(SashimiTheme.textSecondary)
            if model.sessions.isEmpty {
                ServerFocusableMessage(icon: "sparkles.tv", title: "Nobody's watching")
                    .prefersDefaultFocus(in: focusNamespace)
            } else {
                // A grid that wraps, never a sliding rail: every card stays
                // whole on screen and reachable with the remote.
                LazyVGrid(columns: columns, alignment: .leading, spacing: 32) {
                    ForEach(model.sessions) { session in
                        ServerSessionCard(session: session) { selected = session }
                            .prefersDefaultFocus(session.id == model.sessions.first?.id, in: focusNamespace)
                    }
                }
                Text("Select a stream for details, or to stop it or send a message.")
                    .font(Typography.caption)
                    .foregroundStyle(SashimiTheme.textTertiary)
            }
        }
    }
}

/// A selected stream: everything about it, plus Stop and Send a message when
/// the viewer's app accepts remote commands.
struct ServerStreamSheet: View {
    let session: DashboardSession
    @ObservedObject var model: ServerDashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingStop = false
    @State private var composing = false
    @State private var messageText = ""
    @State private var notice: String?

    private var title: String { session.nowPlayingItem?.displayTitle ?? "this stream" }
    private var device: String { session.deviceName ?? "their screen" }

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            SmartPosterImage(itemIds: session.nowPlayingItem?.posterItemIds ?? [], maxWidth: 480, imageTypes: ["Primary"])
                .frame(width: 280, height: 420)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.large))

            VStack(alignment: .leading, spacing: 24) {
                Text(title)
                    .font(Typography.headline)
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 16) {
                    PlayModeBadge(mode: ServerDashboardLogic.playMode(session.transcodingInfo))
                    Text(ServerDashboardLogic.detailLine(for: session))
                        .font(Typography.bodySmall)
                        .foregroundStyle(SashimiTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ServerDashboardLogic.detailRows(for: session)) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 24) {
                            Text(row.label)
                                .foregroundStyle(SashimiTheme.textTertiary)
                                .frame(width: 240, alignment: .leading)
                            Text(row.value)
                                .foregroundStyle(SashimiTheme.textPrimary)
                                .lineLimit(2)
                        }
                        .font(Typography.bodySmall)
                    }
                }
                actions
                if let notice {
                    Text(notice).font(Typography.caption).foregroundStyle(SashimiTheme.success)
                }
            }
        }
        .padding(80)
        .destructiveConfirmation(
            "Stop \(session.userName ?? "this")'s stream?",
            isPresented: $confirmingStop,
            message: "\(title) stops playing on \(device).",
            confirmTitle: "Stop"
        ) {
            Task {
                await model.stop(session)
                dismiss()
            }
        }
        .alert("Send a message", isPresented: $composing) {
            TextField("Message", text: $messageText)
            Button("Send") {
                Task {
                    if await model.message(session, text: messageText) {
                        messageText = ""
                        notice = "Message sent to \(device)."
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown on \(device) for ten seconds.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 24) {
            if session.supportsRemoteControl {
                ActionButton(title: "Stop stream", icon: "stop.fill") { confirmingStop = true }
                ActionButton(title: "Send a message", icon: "text.bubble") { composing = true }
            }
            ActionButton(title: "Close", icon: "xmark") { dismiss() }
        }
        .padding(.top, 12)
        if !session.supportsRemoteControl {
            Text("\(session.client ?? "This app") doesn't take remote commands, so it can't be stopped or messaged from here.")
                .font(Typography.caption)
                .foregroundStyle(SashimiTheme.textTertiary)
        }
    }
}

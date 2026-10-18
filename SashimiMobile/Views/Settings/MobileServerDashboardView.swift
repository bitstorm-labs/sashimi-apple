import SwiftUI

/// The admin Server dashboard on iPhone and iPad (and the Mac through the iOS
/// app): streams, what needs attention, then Activity and Health. Reached from
/// Settings, and only offered to the server's administrators.
struct MobileServerDashboardView: View {
    @StateObject private var model: ServerDashboardViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var stopping: DashboardSession?
    @State private var messaging: DashboardSession?
    @State private var messageText = ""
    @State private var details: DashboardSession?

    /// - Parameter model: injected by tests; the screen makes its own otherwise.
    init(model: ServerDashboardViewModel? = nil) {
        _model = StateObject(wrappedValue: model ?? ServerDashboardViewModel())
    }

    var body: some View {
        content
            .navigationTitle("Server")
            .onAppear { model.attach() }
            .onDisappear { model.detach() }
            .onChange(of: scenePhase) { _, phase in
                model.setSceneActive(phase == .active)
            }
            .confirmationDialog(
                "Stop \(stopping?.userName ?? "this")'s stream?",
                isPresented: isPresent($stopping),
                titleVisibility: .visible,
                presenting: stopping
            ) { session in
                Button("Stop", role: .destructive) {
                    Task { await model.stop(session) }
                }
            } message: { session in
                Text("\(session.nowPlayingItem?.displayTitle ?? "It") stops playing on \(session.deviceName ?? "their screen").")
            }
            .alert("Send a message", isPresented: isPresent($messaging), presenting: messaging) { session in
                TextField("Message", text: $messageText)
                Button("Send") {
                    Task {
                        if await model.message(session, text: messageText) { messageText = "" }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { session in
                Text("Shown on \(session.deviceName ?? "their screen") for ten seconds.")
            }
            .sheet(item: $details) { session in
                NavigationStack { MobileStreamDetailsView(session: session) }
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } }),
                actions: { Button("OK", role: .cancel) {} },
                message: { Text(model.actionError ?? "") }
            )
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Asking the server…")
        case .denied:
            ContentUnavailableView(
                "Administrators only",
                systemImage: "lock",
                description: Text("This server only shows this to its administrators.")
            )
        case .failed:
            ContentUnavailableView {
                Label("Can't reach the server", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Trying again every few seconds.")
            } actions: {
                Button("Try Again") { Task { await model.refreshAll() } }
            }
        case .loaded:
            list
        }
    }

    private var summary: String {
        let parts = [
            "\(model.sessions.count) streaming",
            "\(model.convertingCount) converting",
            "\(ServerDashboardLogic.formatBitrate(model.totalBitrate)) out"
        ]
        return parts.joined(separator: " · ")
    }

    private var list: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary).font(.subheadline)
                    if !model.serverLine.isEmpty {
                        Text(model.serverLine).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Now playing") {
                if model.sessions.isEmpty {
                    Text("Nobody's watching").foregroundStyle(.secondary)
                }
                ForEach(model.sessions) { session in
                    MobileSessionRow(
                        session: session,
                        onStop: { stopping = session },
                        onMessage: { messaging = session },
                        onDetails: { details = session }
                    )
                }
            }

            Section("Needs attention") {
                if model.attention.isEmpty {
                    Label("All clear", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.attention) { row in
                    MobileDotRow(tone: row.tone, text: row.text, value: row.when)
                }
            }

            Section {
                NavigationLink("Activity") { MobileServerActivityView(model: model) }
                NavigationLink("Health") { MobileServerHealthView(model: model) }
            }
        }
        .refreshable { await model.refreshAll() }
    }

    private func isPresent(_ item: Binding<DashboardSession?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// One stream: poster, title, who and where, badge, rate, progress, actions.
private struct MobileSessionRow: View {
    let session: DashboardSession
    let onStop: () -> Void
    let onMessage: () -> Void
    let onDetails: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var mode: PlayMode { ServerDashboardLogic.playMode(session.transcodingInfo) }
    private var item: DashboardNowPlaying? { session.nowPlayingItem }

    var body: some View {
        HStack(spacing: 12) {
            SmartPosterImage(itemIds: item?.posterItemIds ?? [], maxWidth: 120, imageTypes: ["Primary"])
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))

            VStack(alignment: .leading, spacing: 4) {
                Text(item?.displayTitle ?? "")
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(ServerDashboardLogic.viewerLine(session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    MobilePlayModeBadge(mode: mode, short: sizeClass == .compact)
                    Text(ServerDashboardLogic.rateLine(session))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if sizeClass == .regular {
                    Text(ServerDashboardLogic.detailLine(for: session))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: ServerDashboardLogic.progressFraction(
                    positionTicks: session.playState?.positionTicks,
                    runTimeTicks: item?.runTimeTicks
                ))
                .tint(MobileColors.accent)
            }

            Menu {
                if session.supportsRemoteControl {
                    Button("Stop stream", systemImage: "stop.fill", role: .destructive, action: onStop)
                    Button("Send a message", systemImage: "text.bubble", action: onMessage)
                }
                Button("Details", systemImage: "info.circle", action: onDetails)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Stream actions")
        }
    }
}

import SwiftUI

/// Connect Plex for the Watchlist on iPhone, iPad and Mac: Plex's own sign-in
/// page with the PIN polled alongside, as Settings › Requests does it. It needs
/// nothing from Requests, so it works where Requests was never set up.
@MainActor
func connectPlex(model: PlexConnectModel) async {
    guard let pin = await model.begin(strong: true) else { return }
    let page = PlexSignInPage()
    await PlexWebSignIn.run(
        poll: { await model.complete(pin: pin) },
        showPage: { await page.show(model.webSignInURL(for: pin)) },
        closePage: { page.close() },
        isWaiting: { model.isWaiting },
        cancelWaiting: { model.cancel() },
        checksStarted: { model.pinChecks }
    )
}

extension View {
    /// Collects a Connect Plex PIN begun before the app was relaunched, once
    /// per signed-in session: "Your Watchlist now syncs with Plex" when it
    /// links, the switch question when another account already syncs.
    func resumingPlexConnect(session: String) -> some View {
        modifier(ResumePlexConnect(session: session))
    }

    /// What a Connect Plex run says: the switch question when the Watchlist
    /// already syncs with another account, a failure, or that it's linked.
    func plexConnectFeedback(_ model: PlexConnectModel, message: Binding<String?>) -> some View {
        modifier(PlexConnectFeedback(model: model, message: message))
    }

    /// "Disconnect Plex?" before a disconnect: the same question everywhere.
    func disconnectPlexConfirmation(isPresented: Binding<Bool>, disconnect: @escaping () -> Void) -> some View {
        alert(WatchlistText.disconnectQuestion, isPresented: isPresented) {
            Button(WatchlistText.disconnect, role: .destructive, action: disconnect)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(WatchlistText.disconnectMessage)
        }
    }
}

private struct PlexConnectFeedback: ViewModifier {
    @ObservedObject var model: PlexConnectModel
    @Binding var message: String?
    /// The question just answered. Its alert stays down until the model moves
    /// on, so the answer's own work isn't cut short by a dismissal.
    @State private var answered: PlexConnectModel.State?

    func body(content: Content) -> some View {
        content
            .alert(questionTitle, isPresented: questionShown) {
                if case .conflict(let current, _) = model.state {
                    Button(WatchlistText.switchButton) {
                        answered = model.state
                        Task { await model.confirmSwitch() }
                    }
                    Button(WatchlistText.keep(current), role: .cancel) {
                        answered = model.state
                        model.cancel()
                    }
                }
            } message: {
                if case .conflict(let current, _) = model.state {
                    Text(WatchlistText.switchMessage(currentUsername: current))
                }
            }
            // "Switch" couldn't reach Plex: say so beside the question that comes back.
            .onChange(of: model.message) { _, text in
                if let text { message = text }
            }
            .onChange(of: model.state) { _, state in
                switch state {
                case .conflict: break
                case .failed(let text):
                    answered = nil
                    message = text
                case .linked:
                    answered = nil
                    message = WatchlistText.nowSyncs
                default:
                    answered = nil
                }
            }
    }

    private var questionTitle: String {
        if case .conflict(_, let new) = model.state { return WatchlistText.switchQuestion(newUsername: new) }
        return ""
    }

    private var questionShown: Binding<Bool> {
        Binding(
            get: {
                if case .conflict = model.state { return model.state != answered }
                return false
            },
            set: { shown in if !shown { answered = model.state } }
        )
    }
}

/// Settings › Plex: the one Plex row, beside the server and account settings.
/// Hidden without the Watchlist plugin. The screen owns and loads `model`:
/// while the row is hidden this section has no view to run a task from.
struct MobilePlexSettingsSection: View {
    @ObservedObject var model: PlexSettingsModel
    @StateObject private var connect = PlexConnectModel()
    @State private var connectTask: Task<Void, Never>?
    @State private var confirmDisconnect = false
    @State private var message: String?

    var body: some View {
        Group {
            if model.row != .hidden {
                Section {
                    LabeledContent(WatchlistText.plexRowTitle, value: model.status)
                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let progress = connect.progressText {
                        HStack {
                            ProgressView()
                            Text(progress)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { cancel() }
                        }
                    } else {
                        ForEach(model.actions, id: \.self) { action in
                            button(for: action)
                        }
                    }
                } footer: {
                    Text(model.footer)
                }
                .task { await connect.resumePendingIfAny() }
            }
        }
        // No cancel on disappear: a List section "disappears" when scrolled
        // away, and the sign-in flow ends itself when Plex's page closes.
        .plexConnectFeedback(connect, message: $message)
        .disconnectPlexConfirmation(isPresented: $confirmDisconnect) {
            Task { if !(await model.disconnect()) { message = WatchlistText.couldntDisconnect } }
        }
    }

    @ViewBuilder
    private func button(for action: PlexSettingsModel.Action) -> some View {
        switch action {
        case .connect:
            Button(WatchlistText.connect) { start() }
        case .reconnect:
            Button(WatchlistText.reconnect) { start() }
        case .disconnect:
            Button(WatchlistText.disconnect, role: .destructive) { confirmDisconnect = true }
        }
    }

    private func start() {
        message = nil
        connectTask?.cancel()
        connectTask = Task { await connectPlex(model: connect) }
    }

    private func cancel() {
        connectTask?.cancel()
        connectTask = nil
        if connect.isWaiting { connect.cancel() }
    }
}

private struct ResumePlexConnect: ViewModifier {
    let session: String
    @StateObject private var model = PlexConnectModel()
    @State private var message: String?

    func body(content: Content) -> some View {
        content
            .task(id: session) { await model.resumePendingIfAny() }
            .plexConnectFeedback(model, message: $message)
            .listMessage($message)
    }
}

import SwiftUI

/// Settings › Requests (mockup A): connect a Seerr account once. Plex
/// sign-in is a code for plex.tv/link, like the Plex app; the Seerr
/// username form is for the server's local accounts.
struct RequestsSettingsView: View {
    @ObservedObject private var session = SeerrSession.shared
    @ObservedObject private var watchlist = WatchlistStore.shared
    /// The switch question just answered: its alert stays down while the
    /// answer runs (the store may ask the same question again if it fails).
    @State private var answeredSwitch: UUID?
    @State private var serverText = ""
    @State private var showingLocalForm = false
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()
            HStack(alignment: .top, spacing: 60) {
                leftColumn
                    .frame(maxWidth: .infinity, alignment: .top)
                    .focusSection()
                rightPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusSection()
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
        }
        .onAppear {
            serverText = session.serverURL?.absoluteString ?? ""
            Task { await session.refreshPublicSettings() }
        }
        .onDisappear {
            session.cancelPlexSignIn()
            watchlist.notice = nil
        }
        .alert(WatchlistText.switchQuestion(newUsername: openQuestion?.newUsername),
               isPresented: switchQuestionShown, presenting: openQuestion) { question in
            Button(WatchlistText.switchButton) {
                answeredSwitch = question.id
                Task { _ = await watchlist.confirmSwitch() }
            }
            Button(WatchlistText.keep(question.currentUsername), role: .cancel) {
                answeredSwitch = question.id
                watchlist.declineSwitch()
            }
        } message: { question in
            Text(WatchlistText.switchMessage(currentUsername: question.currentUsername))
        }
        .onChange(of: watchlist.pendingSwitch) { _, question in
            if question == nil { answeredSwitch = nil }
        }
        .onChange(of: session.state) { _, state in
            if state.user != nil {
                showingLocalForm = false
                password = ""
            }
        }
    }

    // MARK: Left: server and sign-in choices

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Requests")
                .font(Typography.headline)
                .foregroundStyle(SashimiTheme.textPrimary)

            serverRow

            if let user = session.state.user {
                SettingsInfoRow(label: "Signed in as", value: user.name)
                if let notice = watchlist.notice {
                    Label(notice, systemImage: "checkmark")
                        .font(Typography.caption)
                        .foregroundStyle(SashimiTheme.success)
                        .lineLimit(1)
                        .padding(.horizontal, 24)
                }
                if let failure = watchlist.switchFailure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.caption)
                        .foregroundStyle(SashimiTheme.warning)
                        .padding(.horizontal, 24)
                }
                SettingsOptionRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign Out", subtitle: "Stop requesting from this Apple TV") {
                    Task { await session.signOut() }
                }
            } else {
                if session.state == .expired {
                    Label("Your \(session.applicationTitle) sign-in has expired. Sign in again to keep requesting.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.caption)
                        .foregroundStyle(SashimiTheme.warning)
                }
                SettingsOptionRow(icon: "link", title: "Sign in with Plex", subtitle: "Enter a code at plex.tv/link") {
                    showingLocalForm = false
                    applyServer()
                    session.startPlexCodeSignIn()
                }
                .disabled(!canSignIn)
                if session.localLoginEnabled {
                    SettingsOptionRow(icon: "person.text.rectangle", title: "Use a Seerr username instead", subtitle: "For accounts made on \(session.applicationTitle)") {
                        session.cancelPlexSignIn()
                        applyServer()
                        showingLocalForm = true
                    }
                    .disabled(!canSignIn)
                }
            }

            Text("Requests use your own \(session.applicationTitle) account, the one you sign in to on the website.")
                .font(Typography.caption)
                .foregroundStyle(SashimiTheme.textTertiary)
                .padding(.top, 6)

            if let message = session.errorMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(Typography.caption)
                    .foregroundStyle(SashimiTheme.warning)
            }
        }
    }

    private var serverRow: some View {
        HStack(spacing: 20) {
            Text("Request server")
                .font(Typography.bodySmall)
                .foregroundStyle(SashimiTheme.textSecondary)
            if session.isActive {
                Spacer()
                Text(session.serverURL?.host ?? session.serverURL?.absoluteString ?? "")
                    .font(Typography.bodySmall.weight(.medium))
                    .foregroundStyle(SashimiTheme.textPrimary)
            } else {
                TextField("https://requests.example.com", text: $serverText)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit {
                        applyServer()
                        Task { await session.refreshPublicSettings() }
                    }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, session.isActive ? 16 : 4)
        .background(RoundedRectangle(cornerRadius: 12).fill(SashimiTheme.cardBackground))
    }

    /// Sign-in waits for a valid address: there is no default server.
    private var canSignIn: Bool { SeerrSession.canSignIn(serverText: serverText) }

    /// An address that isn't valid goes back to the saved one (or empty).
    private func applyServer() {
        if !session.setServerAddress(serverText) {
            serverText = session.serverURL?.absoluteString ?? ""
        }
    }

    /// The store's switch question, unless it was just answered: dismissing the
    /// alert doesn't clear it, because "Switch" needs the question (and its held
    /// token) still there to answer it.
    private var openQuestion: WatchlistStore.PendingSwitch? {
        watchlist.pendingSwitch.flatMap { $0.id == answeredSwitch ? nil : $0 }
    }

    private var switchQuestionShown: Binding<Bool> {
        Binding(
            get: { openQuestion != nil },
            set: { if !$0 { answeredSwitch = watchlist.pendingSwitch?.id } }
        )
    }

    // MARK: Right: Plex code, username form, or nothing

    @ViewBuilder
    private var rightPanel: some View {
        switch session.state {
        case .awaitingPlex(let code):
            plexCodePanel(code)
        case .signingIn:
            panel {
                ProgressView().tint(SashimiTheme.accent).scaleEffect(1.5)
                Text("Signing in…")
                    .font(Typography.body)
                    .foregroundStyle(SashimiTheme.textSecondary)
            }
        case .notConfigured, .expired:
            if showingLocalForm { localForm } else { Color.clear }
        case .signedIn:
            Color.clear
        }
    }

    private func plexCodePanel(_ code: String) -> some View {
        panel {
            PlexCodePanel(code: code)
            ActionButton(title: "Cancel", icon: "xmark") {
                session.cancelPlexSignIn()
            }
            .padding(.top, 10)
        }
    }

    private var localForm: some View {
        panel {
            Text("Sign in to \(session.applicationTitle)")
                .font(Typography.title)
                .foregroundStyle(SashimiTheme.textPrimary)
            TextField("Email", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("Password", text: $password)
                .textContentType(.password)
            ActionButton(title: "Sign In", icon: "arrow.right", isPrimary: true) {
                applyServer()
                Task { await session.signInLocal(email: email, password: password) }
            }
            .disabled(email.isEmpty || password.isEmpty || !canSignIn)
        }
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 20) {
            content()
        }
        .multilineTextAlignment(.center)
        .padding(50)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: CornerRadius.large).fill(SashimiTheme.cardBackground))
    }
}

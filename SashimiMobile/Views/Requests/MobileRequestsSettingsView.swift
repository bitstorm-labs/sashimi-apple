import SwiftUI

/// Settings › Requests on iPhone and iPad: connect a Seerr account once.
/// Plex sign-in opens Plex's own sign-in page in a browser sheet (no code to
/// type); the Seerr username form is for the server's local accounts.
struct MobileRequestsSettingsView: View {
    @ObservedObject private var session = SeerrSession.shared
    @ObservedObject private var watchlist = WatchlistStore.shared
    /// The switch question just answered: its alert stays down while the
    /// answer runs (the store may ask the same question again if it fails).
    @State private var answeredSwitch: UUID?
    @State private var serverText = ""
    @State private var email = ""
    @State private var password = ""
    @State private var plexTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                if session.isServerAddressManaged {
                    LabeledContent {
                        Label(WatchlistV2Text.setByYourServer, systemImage: "lock.fill")
                    } label: {
                        Text(WatchlistV2Text.requestsServer)
                    }
                } else if session.isActive {
                    LabeledContent("Request server", value: session.serverURL?.host ?? session.serverURL?.absoluteString ?? "")
                } else {
                    TextField("Request server", text: $serverText, prompt: Text("https://requests.example.com"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(applyServer)
                }
            } footer: {
                Text("Requests use your own \(session.applicationTitle) account, the one you sign in to on the website.")
            }

            if let user = session.state.user {
                Section {
                    LabeledContent("Signed in as", value: user.name)
                    if let notice = watchlist.notice {
                        Label(notice, systemImage: "checkmark")
                            .lineLimit(1)
                            .foregroundStyle(MobileColors.success)
                    }
                    if let failure = watchlist.switchFailure {
                        Label(failure, systemImage: "exclamationmark.circle")
                            .foregroundStyle(MobileColors.warning)
                    }
                    Button("Sign Out", role: .destructive) {
                        Task { await session.signOut() }
                    }
                }
            } else {
                signInSections
            }

            if let message = session.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(MobileColors.warning)
                }
            }
        }
        .navigationTitle("Requests")
        .onAppear {
            serverText = session.serverURL?.absoluteString ?? ""
            Task {
                // The server may set (or stop setting) the address at any time.
                await SashimiListsFeatures.shared.refresh()
                serverText = session.serverURL?.absoluteString ?? ""
                await session.refreshPublicSettings()
            }
        }
        .onDisappear {
            plexTask?.cancel()
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
        .onChange(of: session.isActive) { _, active in
            if active { password = "" }
        }
    }

    @ViewBuilder
    private var signInSections: some View {
        Section {
            if session.state == .expired {
                Label("Your \(session.applicationTitle) sign-in has expired. Sign in again to keep requesting.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(MobileColors.warning)
            }
            switch session.state {
            case .awaitingPlex, .signingIn:
                HStack {
                    ProgressView()
                    Text(session.state == .signingIn ? "Signing in…" : "Waiting for Plex…")
                        .foregroundStyle(MobileColors.textSecondary)
                    Spacer()
                    Button("Cancel") {
                        plexTask?.cancel()
                        session.cancelPlexSignIn()
                    }
                }
            default:
                Button {
                    signInWithPlex()
                } label: {
                    Label("Sign in with Plex", systemImage: "link")
                }
                .disabled(!canSignIn)
            }
        }

        if session.localLoginEnabled {
            Section("Use a Seerr username instead") {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button("Sign In") {
                    applyServer()
                    Task { await session.signInLocal(email: email, password: password) }
                }
                .disabled(email.isEmpty || password.isEmpty || session.state == .signingIn || !canSignIn)
            }
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

    /// Sign-in waits for a valid address: there is no default server.
    private var canSignIn: Bool { session.isServerAddressManaged || SeerrSession.canSignIn(serverText: serverText) }

    /// An address that isn't valid goes back to the saved one (or empty).
    private func applyServer() {
        guard !session.isServerAddressManaged else { return }
        if !session.setServerAddress(serverText) {
            serverText = session.serverURL?.absoluteString ?? ""
        }
    }

    /// Plex's web sign-in with the PIN polled alongside. The poll finishes
    /// the sign-in and closes the page; if the person closes it first, the
    /// poll gets a moment to see a token that just landed.
    private func signInWithPlex() {
        applyServer()
        plexTask?.cancel()
        plexTask = Task {
            guard let pin = await session.beginPlexSignIn(strong: true) else { return }
            let page = PlexSignInPage()
            await PlexWebSignIn.run(
                poll: { await session.completePlexSignIn(pin: pin) },
                showPage: { await page.show(session.plexWebSignInURL(for: pin)) },
                closePage: { page.close() },
                isWaiting: {
                    if case .awaitingPlex = session.state { return true }
                    return false
                },
                cancelWaiting: { session.cancelPlexSignIn() },
                checksStarted: { session.plexPinChecks }
            )
        }
    }
}

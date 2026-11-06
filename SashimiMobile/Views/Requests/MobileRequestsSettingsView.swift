import AuthenticationServices
import SwiftUI

/// Settings › Requests on iPhone and iPad: connect a Seerr account once.
/// Plex sign-in opens Plex's own sign-in page in a browser sheet (no code to
/// type); the Seerr username form is for the server's local accounts.
struct MobileRequestsSettingsView: View {
    @ObservedObject private var session = SeerrSession.shared
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var serverText = ""
    @State private var email = ""
    @State private var password = ""
    @State private var plexTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                if session.isActive {
                    LabeledContent("Request server", value: session.serverURL.host ?? session.serverURL.absoluteString)
                } else {
                    TextField("Request server", text: $serverText, prompt: Text("https://bitstorm.ca"))
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
                    NavigationLink {
                        MobileSeerrRequestsView()
                    } label: {
                        Label("Your Requests", systemImage: "tray.full")
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
            serverText = session.serverURL.absoluteString
            Task { await session.refreshPublicSettings() }
        }
        .onDisappear {
            plexTask?.cancel()
            session.cancelPlexSignIn()
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
                .disabled(email.isEmpty || password.isEmpty || session.state == .signingIn)
            }
        }
    }

    private func applyServer() {
        if !session.setServerAddress(serverText) {
            serverText = session.serverURL.absoluteString
        }
    }

    /// Plex's web sign-in with the PIN polled alongside: whichever way the
    /// page closes, a linked PIN finishes the sign-in.
    private func signInWithPlex() {
        applyServer()
        plexTask?.cancel()
        plexTask = Task {
            guard let pin = await session.beginPlexSignIn(strong: true) else { return }
            let poll = Task { await session.completePlexSignIn(pin: pin) }
            _ = try? await webAuthenticationSession.authenticate(
                using: session.plexWebSignInURL(for: pin),
                callbackURLScheme: "sashimi"
            )
            // The page closed (signed in, or dismissed). Give the poll a
            // moment to see the token before calling it off.
            for _ in 0..<5 {
                guard case .awaitingPlex = session.state, !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(1))
            }
            if case .awaitingPlex = session.state {
                poll.cancel()
                session.cancelPlexSignIn()
            }
        }
    }
}

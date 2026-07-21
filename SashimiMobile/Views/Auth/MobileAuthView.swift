import SwiftUI

struct MobileAuthView: View {
    /// Provided when shown as the Add Server sheet — renders a Cancel button so
    /// there's always an obvious way back. nil for the root login (nothing to
    /// cancel to).
    var onCancel: (() -> Void)?
    /// Called after a successful sign-in — lets a presenting sheet dismiss even
    /// when no new server was added (e.g. re-authenticating an existing one).
    var onComplete: (() -> Void)?
    /// Pre-fills and jumps straight to the password step for this server (used
    /// to re-authenticate a saved server whose session expired).
    var prefillServerURL: URL?

    @EnvironmentObject var sessionManager: SessionManager
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showLogin = false
    @State private var normalizedServerURL: URL?

    var body: some View {
        // No NavigationStack here on purpose: this view is always hosted inside
        // one (the root login wraps it; the Add Server sheet wraps it with a
        // Cancel toolbar). A nested stack here would shadow that Cancel button.
        Form {
            if !showLogin {
                serverEntrySection
            } else {
                loginSection
            }
        }
        .navigationTitle(showLogin ? "Sign In" : "Connect to Server")
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            guard let prefillServerURL, !showLogin else { return }
            await JellyfinClient.shared.configure(serverURL: prefillServerURL)
            serverURL = prefillServerURL.absoluteString
            normalizedServerURL = prefillServerURL
            showLogin = true
        }
    }

    private var serverEntrySection: some View {
        Group {
            Section {
                TextField("Server URL", text: $serverURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Enter your Jellyfin server address")
            } footer: {
                Text("Example: https://jellyfin.example.com")
            }

            Section {
                Button {
                    connectToServer()
                } label: {
                    if isConnecting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(serverURL.isEmpty || isConnecting)
            }
        }
    }

    private var loginSection: some View {
        Group {
            Section {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)
                    .textContentType(.password)
            } header: {
                Text("Enter your credentials")
            }

            Section {
                Button {
                    signIn()
                } label: {
                    if isConnecting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(username.isEmpty || isConnecting)

                Button {
                    showLogin = false
                    serverURL = ""
                    normalizedServerURL = nil
                } label: {
                    Text("Use Different Server")
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func connectToServer() {
        guard !serverURL.isEmpty else { return }

        isConnecting = true
        errorMessage = nil

        Task {
            // Normalize URL
            var urlString = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
                urlString = "https://" + urlString
            }
            if urlString.hasSuffix("/") {
                urlString = String(urlString.dropLast())
            }

            guard let url = URL(string: urlString) else {
                await MainActor.run {
                    isConnecting = false
                    errorMessage = "Invalid server URL"
                }
                return
            }

            do {
                // Test connection by configuring and trying to get libraries
                await JellyfinClient.shared.configure(serverURL: url)

                await MainActor.run {
                    isConnecting = false
                    normalizedServerURL = url
                    showLogin = true
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    errorMessage = "Connection failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func signIn() {
        guard !username.isEmpty, let url = normalizedServerURL else { return }

        isConnecting = true
        errorMessage = nil

        Task {
            do {
                try await sessionManager.login(serverURL: url, username: username, password: password)
                await MainActor.run {
                    isConnecting = false
                    onComplete?()
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    errorMessage = "Sign in failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

import SwiftUI

struct MobileAuthView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showLogin = false
    @State private var normalizedServerURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                if !showLogin {
                    serverEntrySection
                } else {
                    loginSection
                }
            }
            .navigationTitle(showLogin ? "Sign In" : "Connect to Server")
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
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

                Button("Use Different Server") {
                    showLogin = false
                    serverURL = ""
                    normalizedServerURL = nil
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

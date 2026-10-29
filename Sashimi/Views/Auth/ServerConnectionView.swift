import SwiftUI

// MARK: - Server Connection Types

enum ServerConnectionField {
    case serverAddress
    case username
    case password
    case connectButton
    case cancelSignInButton
    case quickConnectButton
    case quickConnectCancel
    case quickConnectNewCode
}

enum ServerValidationState: Equatable {
    case idle
    case valid
    case invalid(String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

// MARK: - Server Connection View

// Single-screen connection form: server entry, discovery, and login steps all
// live here, so the body runs a little long.
// swiftlint:disable:next type_body_length
struct ServerConnectionView: View {
    /// When presented as a sheet (Add Server), this provides an explicit,
    /// always-focusable way out — the initial login screen leaves it nil.
    var onCancel: (() -> Void)?
    /// Called after a successful sign-in — lets a presenting cover dismiss even
    /// when no new server was added (re-authenticating an existing one).
    var onComplete: (() -> Void)?
    /// Pre-fill for re-authenticating a saved server whose session expired:
    /// the server + username are filled and focus jumps to the password.
    var prefillServerURL: URL?
    var prefillUsername: String?

    @EnvironmentObject private var sessionManager: SessionManager
    @StateObject private var serverDiscovery = ServerDiscovery()

    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showDiscoveredServers = false
    /// The sign-in attempt in flight, so the user can cancel it (#476).
    @State private var signInTask: Task<Void, Never>?
    /// Quick Connect (#800): offered only when the server has it enabled.
    @StateObject private var quickConnect = QuickConnectViewModel()

    // Validation state
    @State private var serverAddressValidation: ServerValidationState = .idle
    @State private var usernameValidation: ServerValidationState = .idle
    @State private var hasAttemptedSubmit = false

    @FocusState private var focusedField: ServerConnectionField?

    var body: some View {
        VStack(spacing: 60) {
            VStack(spacing: 16) {
                Text("Sashimi")
                    .font(.system(size: 76, weight: .bold))

                Text("Jellyfin Client")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            if quickConnect.isActive {
                QuickConnectPanel(
                    viewModel: quickConnect,
                    focusedField: $focusedField,
                    onCancel: cancelQuickConnect
                )
            } else {
                signInForm
            }
        }
        .padding(80)
        .overlay(alignment: .topLeading) {
            if let onCancel {
                Button {
                    onCancel()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                        Text("Cancel")
                    }
                    .font(.callout)
                }
                .padding(40)
            }
        }
        .onAppear {
            if let prefillServerURL {
                serverAddress = prefillServerURL.absoluteString
                validateServerAddress(serverAddress)
                if let prefillUsername {
                    username = prefillUsername
                    validateUsername(prefillUsername)
                }
                focusedField = .password
            } else {
                focusedField = .serverAddress
            }
            quickConnect.onSignedIn = { onComplete?() }
        }
        // Leaving the screen (signed in, sheet dismissed) stops any poll.
        .onDisappear {
            quickConnect.cancel()
        }
        // Back on the code screen returns to the form instead of leaving it.
        .onExitCommand(perform: quickConnect.isActive ? { cancelQuickConnect() } : nil)
        // Re-ask the server whenever the address settles on a valid URL.
        .task(id: validServerURL) {
            let url = validServerURL
            if url != nil {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
            }
            await quickConnect.refreshAvailability(for: url)
        }
        .onChange(of: quickConnect.phase) { _, phase in
            switch phase {
            case .requesting, .waiting:
                if focusedField != .quickConnectCancel { focusedField = .quickConnectCancel }
            case .expired, .failed:
                focusedField = .quickConnectNewCode
            case .idle, .signingIn, .signedIn:
                break
            }
        }
    }

    /// The address as a URL once it passes validation; nil otherwise.
    private var validServerURL: URL? {
        guard serverAddressValidation.isValid else { return nil }
        return URL(string: serverAddress)
    }

    private func cancelQuickConnect() {
        quickConnect.cancel()
        focusedField = quickConnect.isAvailable ? .quickConnectButton : .connectButton
    }

    /// Server, username and password, plus the Quick Connect entry point.
    private var signInForm: some View {
    VStack(spacing: 40) {
        if sessionManager.logoutReason == .sessionExpired {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Your session has expired. Please log in again.")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.yellow.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }

        VStack(spacing: 16) {
            // Server Address Field with validation
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    TextField("Server Address (e.g., http://192.168.1.100:8096)", text: $serverAddress)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .serverAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: serverAddress) { _, newValue in
                            validateServerAddress(newValue)
                        }

                    // Validation status icon
                    if !serverAddress.isEmpty {
                        validationIcon(for: serverAddressValidation)
                    }
                }
                .padding()
                .background(validationFieldBackground(for: serverAddressValidation))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(validationBorderColor(for: serverAddressValidation), lineWidth: 2)
                )

                // Inline validation message
                if let error = serverAddressValidation.errorMessage, hasAttemptedSubmit || !serverAddress.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                        Text(error)
                            .font(.caption)
                    }
                    .foregroundStyle(.red)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: serverAddressValidation)

            // Server discovery button
            Button {
                showDiscoveredServers = true
                serverDiscovery.startDiscovery()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("Find Servers on Network")
                }
                .font(.callout)
                .foregroundStyle(SashimiTheme.accent)
            }
            .buttonStyle(.plain)
        }

        // Discovered servers list
        if showDiscoveredServers {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Discovered Servers")
                        .font(.headline)
                        .foregroundStyle(SashimiTheme.textSecondary)

                    if serverDiscovery.isSearching {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }

                if serverDiscovery.discoveredServers.isEmpty && !serverDiscovery.isSearching {
                    Text("No servers found on your network")
                        .font(.callout)
                        .foregroundStyle(SashimiTheme.textTertiary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(serverDiscovery.discoveredServers) { server in
                        Button {
                            if let url = server.url {
                                serverAddress = url.absoluteString
                                showDiscoveredServers = false
                                focusedField = .username
                            }
                        } label: {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(SashimiTheme.accent)
                                VStack(alignment: .leading) {
                                    Text(server.name)
                                        .foregroundStyle(SashimiTheme.textPrimary)
                                    Text("\(server.address):\(server.port)")
                                        .font(.caption)
                                        .foregroundStyle(SashimiTheme.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(SashimiTheme.textTertiary)
                            }
                            .padding()
                            .background(SashimiTheme.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }

        // Username Field with validation
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                TextField("Username", text: $username)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: username) { _, newValue in
                        validateUsername(newValue)
                    }

                // Validation status icon
                if !username.isEmpty || hasAttemptedSubmit {
                    validationIcon(for: usernameValidation)
                }
            }
            .padding()
            .background(validationFieldBackground(for: usernameValidation))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(validationBorderColor(for: usernameValidation), lineWidth: 2)
            )

            // Inline validation message
            if let error = usernameValidation.errorMessage, hasAttemptedSubmit {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                }
                .foregroundStyle(.red)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: usernameValidation)

        SecureField("Password", text: $password)
            .textFieldStyle(.plain)
            .padding()
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .focused($focusedField, equals: .password)

        if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .font(.callout)
        }

        Button {
            connect()
        } label: {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Text("Connect")
                    .frame(maxWidth: .infinity)
            }
        }
        .disabled(isLoading || !isFormValid)
        .focused($focusedField, equals: .connectButton)

        // The Connect button is disabled while signing in, so this is
        // where focus lands: always a way out of a slow attempt.
        if isLoading {
            Button("Cancel") {
                cancelSignIn()
            }
            .focused($focusedField, equals: .cancelSignInButton)
        } else if quickConnect.isAvailable, let url = validServerURL {
            // Directly below Connect, so Down from Connect reaches it.
            Button {
                quickConnect.start(serverURL: url)
            } label: {
                Label("Sign in with Quick Connect", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
            }
            .focused($focusedField, equals: .quickConnectButton)
        }
    }
    .frame(maxWidth: 600)
    }

    private var isFormValid: Bool {
        serverAddressValidation.isValid && usernameValidation.isValid
    }

    // MARK: - Validation Functions

    private func validateServerAddress(_ address: String) {
        if address.isEmpty {
            serverAddressValidation = .idle
            return
        }

        // Check for basic URL format
        guard let url = URL(string: address) else {
            serverAddressValidation = .invalid("Invalid URL format")
            return
        }

        // Check for http or https scheme
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            serverAddressValidation = .invalid("URL must start with http:// or https://")
            return
        }

        // Check for host
        guard let host = url.host, !host.isEmpty else {
            serverAddressValidation = .invalid("URL must include a server address")
            return
        }

        // Valid!
        serverAddressValidation = .valid
    }

    private func validateUsername(_ name: String) {
        if name.isEmpty {
            usernameValidation = hasAttemptedSubmit ? .invalid("Username is required") : .idle
            return
        }

        // Valid!
        usernameValidation = .valid
    }

    @ViewBuilder
    private func validationIcon(for state: ServerValidationState) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .valid:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green)
        case .invalid:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.red)
        }
    }

    private func validationFieldBackground(for state: ServerValidationState) -> Color {
        switch state {
        case .idle:
            return Color.white.opacity(0.1)
        case .valid:
            return Color.green.opacity(0.1)
        case .invalid:
            return Color.red.opacity(0.1)
        }
    }

    private func validationBorderColor(for state: ServerValidationState) -> Color {
        switch state {
        case .idle:
            return .clear
        case .valid:
            return .green.opacity(0.5)
        case .invalid:
            return .red.opacity(0.7)
        }
    }

    private func connect() {
        hasAttemptedSubmit = true

        // Run all validations
        validateServerAddress(serverAddress)
        validateUsername(username)

        // Check if form is valid
        guard isFormValid else {
            return
        }

        guard let url = URL(string: serverAddress) else {
            errorMessage = "Invalid server address"
            return
        }

        isLoading = true
        errorMessage = nil
        focusedField = .cancelSignInButton

        signInTask = Task {
            do {
                try await sessionManager.login(serverURL: url, username: username, password: password)
                guard !Task.isCancelled else { return }
                onComplete?()
            } catch {
                // A cancelled attempt has already reset the form.
                guard !Task.isCancelled else { return }
                errorMessage = SignInFailure.message(for: error) ?? error.localizedDescription
            }
            isLoading = false
            signInTask = nil
        }
    }

    /// Abandons the attempt in flight and returns the form to idle, with no
    /// error: the user chose to stop, nothing failed.
    private func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        isLoading = false
        errorMessage = nil
        focusedField = .connectButton
    }
}

#Preview {
    ServerConnectionView()
        .environmentObject(SessionManager.shared)
}

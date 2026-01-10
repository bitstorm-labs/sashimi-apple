import SwiftUI

struct ServerConnectionView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @StateObject private var serverDiscovery = ServerDiscovery()

    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showDiscoveredServers = false

    // Validation state
    @State private var serverAddressValidation: ValidationState = .idle
    @State private var usernameValidation: ValidationState = .idle
    @State private var hasAttemptedSubmit = false

    @FocusState private var focusedField: Field?

    enum Field {
        case serverAddress
        case username
        case password
        case connectButton
    }

    enum ValidationState: Equatable {
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

    var body: some View {
        VStack(spacing: 60) {
            VStack(spacing: 16) {
                Text("Sashimi")
                    .font(.system(size: 76, weight: .bold))

                Text("Jellyfin Client")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

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
                        TextField("Server Address (e.g., http://192.168.1.100:8096)", text: $serverAddress)
                            .textFieldStyle(.plain)
                            .padding()
                            .background(validationFieldBackground(for: serverAddressValidation))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(validationBorderColor(for: serverAddressValidation), lineWidth: 2)
                            )
                            .focused($focusedField, equals: .serverAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: serverAddress) { _, newValue in
                                validateServerAddress(newValue)
                            }

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
                    TextField("Username", text: $username)
                        .textFieldStyle(.plain)
                        .padding()
                        .background(validationFieldBackground(for: usernameValidation))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(validationBorderColor(for: usernameValidation), lineWidth: 2)
                        )
                        .focused($focusedField, equals: .username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: username) { _, newValue in
                            validateUsername(newValue)
                        }

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
            }
            .frame(maxWidth: 600)
        }
        .padding(80)
        .onAppear {
            focusedField = .serverAddress
        }
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

    private func validationFieldBackground(for state: ValidationState) -> Color {
        switch state {
        case .idle:
            return Color.white.opacity(0.1)
        case .valid:
            return Color.green.opacity(0.1)
        case .invalid:
            return Color.red.opacity(0.1)
        }
    }

    private func validationBorderColor(for state: ValidationState) -> Color {
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

        Task {
            do {
                try await sessionManager.login(serverURL: url, username: username, password: password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#Preview {
    ServerConnectionView()
        .environmentObject(SessionManager.shared)
}

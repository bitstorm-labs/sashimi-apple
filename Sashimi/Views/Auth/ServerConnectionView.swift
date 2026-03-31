import SwiftUI

// MARK: - Server Connection Types

enum ServerConnectionField {
    case serverAddress
    case username
    case password
    case connectButton
    case plexSignIn
    case plexCancel
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

// MARK: - Plex Auth State

enum PlexAuthState: Equatable {
    case idle
    case requestingPin
    case waitingForLink(code: String, pinId: Int)
    case authenticated(token: String)
    case selectingServer
    case error(String)

    static func == (lhs: PlexAuthState, rhs: PlexAuthState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.requestingPin, .requestingPin): return true
        case (.waitingForLink(let a, let b), .waitingForLink(let c, let d)): return a == c && b == d
        case (.authenticated(let a), .authenticated(let b)): return a == b
        case (.selectingServer, .selectingServer): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Server Connection View

struct ServerConnectionView: View {
    @EnvironmentObject private var serverManager: ServerManager
    @StateObject private var serverDiscovery = ServerDiscovery()

    // Server type selector
    @State private var selectedServerType: ServerType = .jellyfin

    // Jellyfin state
    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showDiscoveredServers = false

    // Jellyfin validation state
    @State private var serverAddressValidation: ServerValidationState = .idle
    @State private var usernameValidation: ServerValidationState = .idle
    @State private var hasAttemptedSubmit = false

    // Plex state
    @State private var plexAuthState: PlexAuthState = .idle
    @State private var plexServers: [PlexResource] = []
    @State private var plexAuthToken: String?
    @State private var plexPollingTask: Task<Void, Never>?

    @FocusState private var focusedField: ServerConnectionField?

    var body: some View {
        VStack(spacing: 60) {
            // Header
            VStack(spacing: 16) {
                Text("Sashimi")
                    .font(.system(size: 76, weight: .bold))

                Text("Media Client")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            // Server type selector
            HStack(spacing: 20) {
                serverTypeButton(.jellyfin, label: "Jellyfin", icon: "server.rack")
                serverTypeButton(.plex, label: "Plex", icon: "play.square.stack")
            }

            // Content based on selected server type
            if selectedServerType == .jellyfin {
                jellyfinLoginForm
            } else {
                plexLoginFlow
            }
        }
        .padding(80)
        .onAppear {
            focusedField = .serverAddress
        }
        .onChange(of: selectedServerType) { _, newValue in
            if newValue == .jellyfin {
                cancelPlexPolling()
            }
        }
        .onDisappear {
            cancelPlexPolling()
        }
    }

    // MARK: - Server Type Selector Button

    @ViewBuilder
    private func serverTypeButton(_ type: ServerType, label: String, icon: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedServerType = type
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                Text(label)
                    .font(.system(size: 24, weight: .semibold))
            }
            .frame(maxWidth: 260)
            .padding(.vertical, 18)
            .padding(.horizontal, 30)
            .background(selectedServerType == type ? SashimiTheme.accent.opacity(0.3) : Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selectedServerType == type ? SashimiTheme.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Jellyfin Login Form

    private var jellyfinLoginForm: some View {
        VStack(spacing: 40) {
            if serverManager.logoutReason == .sessionExpired {
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
        }
        .frame(maxWidth: 600)
    }

    // MARK: - Plex Login Flow

    private var plexLoginFlow: some View {
        VStack(spacing: 40) {
            switch plexAuthState {
            case .idle:
                plexSignInButton

            case .requestingPin:
                ProgressView()
                    .scaleEffect(1.5)
                Text("Requesting PIN...")
                    .font(.title3)
                    .foregroundStyle(SashimiTheme.textSecondary)

            case .waitingForLink(let code, _):
                plexWaitingForLinkView(code: code)

            case .authenticated:
                ProgressView()
                    .scaleEffect(1.5)
                Text("Loading servers...")
                    .font(.title3)
                    .foregroundStyle(SashimiTheme.textSecondary)

            case .selectingServer:
                plexServerSelectionView

            case .error(let message):
                plexErrorView(message: message)
            }
        }
        .frame(maxWidth: 600)
    }

    private var plexSignInButton: some View {
        Button {
            requestPlexPin()
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "play.square.stack.fill")
                    .font(.system(size: 28))
                Text("Sign in with Plex")
                    .font(.system(size: 28, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(Color(red: 0.90, green: 0.65, blue: 0.0).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(red: 0.90, green: 0.65, blue: 0.0).opacity(0.6), lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .focused($focusedField, equals: .plexSignIn)
    }

    @ViewBuilder
    private func plexWaitingForLinkView(code: String) -> some View {
        VStack(spacing: 30) {
            VStack(spacing: 12) {
                Text("Go to")
                    .font(.title3)
                    .foregroundStyle(SashimiTheme.textSecondary)
                Text("plex.tv/link")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(SashimiTheme.accent)
                Text("and enter the code:")
                    .font(.title3)
                    .foregroundStyle(SashimiTheme.textSecondary)
            }

            Text(code)
                .font(.system(size: 72, weight: .bold, design: .monospaced))
                .foregroundStyle(SashimiTheme.textPrimary)
                .padding(.horizontal, 40)
                .padding(.vertical, 20)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(SashimiTheme.accent.opacity(0.4), lineWidth: 2)
                )

            HStack(spacing: 12) {
                ProgressView()
                Text("Waiting for authorization...")
                    .font(.callout)
                    .foregroundStyle(SashimiTheme.textTertiary)
            }

            Button {
                cancelPlexPolling()
                plexAuthState = .idle
            } label: {
                Text("Cancel")
                    .foregroundStyle(SashimiTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .focused($focusedField, equals: .plexCancel)
        }
    }

    private var plexServerSelectionView: some View {
        VStack(spacing: 24) {
            Text("Select your server")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(SashimiTheme.textPrimary)

            if plexServers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(SashimiTheme.warning)
                    Text("No Plex servers found on your account.")
                        .font(.title3)
                        .foregroundStyle(SashimiTheme.textSecondary)
                    Button {
                        plexAuthState = .idle
                        plexAuthToken = nil
                    } label: {
                        Text("Try Again")
                            .foregroundStyle(SashimiTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ForEach(plexServers, id: \.clientIdentifier) { resource in
                    Button {
                        selectPlexServer(resource)
                    } label: {
                        HStack {
                            Image(systemName: "server.rack")
                                .font(.system(size: 24))
                                .foregroundStyle(SashimiTheme.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(resource.name)
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundStyle(SashimiTheme.textPrimary)
                                if let connection = resource.connections.first(where: { !$0.local })
                                    ?? resource.connections.first {
                                    Text(connection.uri)
                                        .font(.callout)
                                        .foregroundStyle(SashimiTheme.textTertiary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(SashimiTheme.textTertiary)
                        }
                        .padding(20)
                        .background(SashimiTheme.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                cancelPlexPolling()
                plexAuthState = .idle
                plexAuthToken = nil
                plexServers = []
            } label: {
                Text("Cancel")
                    .foregroundStyle(SashimiTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func plexErrorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(SashimiTheme.error)

            Text(message)
                .font(.title3)
                .foregroundStyle(SashimiTheme.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                plexAuthState = .idle
            } label: {
                Text("Try Again")
                    .font(.title3)
                    .foregroundStyle(SashimiTheme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Plex Auth Logic

    private func requestPlexPin() {
        plexAuthState = .requestingPin

        Task {
            do {
                let client = PlexClient()
                let pin = try await client.requestPin()
                plexAuthState = .waitingForLink(code: pin.code, pinId: pin.id)
                startPlexPolling(pinId: pin.id, client: client)
            } catch {
                plexAuthState = .error("Failed to request PIN: \(error.localizedDescription)")
            }
        }
    }

    private func startPlexPolling(pinId: Int, client: PlexClient) {
        cancelPlexPolling()

        plexPollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)

                if Task.isCancelled { break }

                do {
                    let pin = try await client.checkPin(pinId: pinId)
                    if let token = pin.authToken, !token.isEmpty {
                        plexAuthToken = token
                        plexAuthState = .authenticated(token: token)
                        await loadPlexServers(token: token, client: client)
                        return
                    }
                } catch {
                    // Silently continue polling on transient errors
                }
            }
        }
    }

    private func loadPlexServers(token: String, client: PlexClient) async {
        do {
            let servers = try await client.getServers(token: token)
            plexServers = servers
            plexAuthState = .selectingServer
        } catch {
            plexAuthState = .error("Failed to load servers: \(error.localizedDescription)")
        }
    }

    private func selectPlexServer(_ resource: PlexResource) {
        guard let token = plexAuthToken else { return }

        isLoading = true
        Task {
            do {
                try await serverManager.addPlexServer(token: token, resource: resource)
            } catch {
                plexAuthState = .error("Failed to connect: \(error.localizedDescription)")
            }
            isLoading = false
        }
    }

    private func cancelPlexPolling() {
        plexPollingTask?.cancel()
        plexPollingTask = nil
    }

    // MARK: - Jellyfin Validation

    private var isFormValid: Bool {
        serverAddressValidation.isValid && usernameValidation.isValid
    }

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

        Task {
            do {
                try await serverManager.addJellyfinServer(url: url, username: username, password: password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#Preview {
    ServerConnectionView()
        .environmentObject(ServerManager.shared)
}

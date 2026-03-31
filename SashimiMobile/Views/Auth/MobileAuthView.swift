import SwiftUI

// MARK: - Mobile Plex Auth State

private enum MobilePlexAuthState: Equatable {
    case idle
    case requestingPin
    case waitingForLink(code: String, pinId: Int)
    case authenticated(token: String)
    case selectingServer
    case error(String)

    static func == (lhs: MobilePlexAuthState, rhs: MobilePlexAuthState) -> Bool {
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

struct MobileAuthView: View {
    @EnvironmentObject var serverManager: ServerManager

    // Server type selection
    @State private var selectedServerType: ServerType = .jellyfin

    // Jellyfin state
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showLogin = false
    @State private var normalizedServerURL: URL?

    // Plex state
    @State private var plexAuthState: MobilePlexAuthState = .idle
    @State private var plexServers: [PlexResource] = []
    @State private var plexAuthToken: String?
    @State private var plexPollingTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                // Server type picker
                Section {
                    Picker("Server Type", selection: $selectedServerType) {
                        Text("Jellyfin").tag(ServerType.jellyfin)
                        Text("Plex").tag(ServerType.plex)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 4)
                }

                if selectedServerType == .jellyfin {
                    jellyfinSections
                } else {
                    plexSections
                }
            }
            .navigationTitle(navigationTitle)
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
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
    }

    private var navigationTitle: String {
        if selectedServerType == .jellyfin {
            return showLogin ? "Sign In" : "Connect to Server"
        } else {
            switch plexAuthState {
            case .selectingServer:
                return "Select Server"
            default:
                return "Sign in with Plex"
            }
        }
    }

    // MARK: - Jellyfin Sections

    private var jellyfinSections: some View {
        Group {
            if !showLogin {
                serverEntrySection
            } else {
                loginSection
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

    // MARK: - Plex Sections

    @ViewBuilder
    private var plexSections: some View {
        switch plexAuthState {
        case .idle:
            Section {
                Button {
                    requestPlexPin()
                } label: {
                    HStack {
                        Image(systemName: "play.square.stack.fill")
                        Text("Sign in with Plex")
                    }
                    .frame(maxWidth: .infinity)
                    .font(.headline)
                }
            } footer: {
                Text("You will receive a code to enter at plex.tv/link")
            }

        case .requestingPin:
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Requesting PIN...")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

        case .waitingForLink(let code, _):
            Section {
                VStack(spacing: 16) {
                    Text("Go to")
                        .foregroundStyle(.secondary)
                    Text("plex.tv/link")
                        .font(.title2.bold())
                        .foregroundStyle(.blue)
                    Text("and enter the code:")
                        .foregroundStyle(.secondary)

                    Text(code)
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for authorization...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                Button(role: .cancel) {
                    cancelPlexPolling()
                    plexAuthState = .idle
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
            }

        case .authenticated:
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading servers...")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

        case .selectingServer:
            if plexServers.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("No Plex servers found on your account.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section {
                    Button("Try Again") {
                        plexAuthState = .idle
                        plexAuthToken = nil
                    }
                }
            } else {
                Section {
                    ForEach(plexServers, id: \.clientIdentifier) { resource in
                        Button {
                            selectPlexServer(resource)
                        } label: {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(resource.name)
                                        .foregroundStyle(.primary)
                                    if let connection = resource.connections.first(where: { !$0.local })
                                        ?? resource.connections.first {
                                        Text(connection.uri)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if isConnecting {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isConnecting)
                    }
                } header: {
                    Text("Select your server")
                }

                Section {
                    Button(role: .cancel) {
                        cancelPlexPolling()
                        plexAuthState = .idle
                        plexAuthToken = nil
                        plexServers = []
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                    }
                }
            }

        case .error(let message):
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                Button("Try Again") {
                    plexAuthState = .idle
                }
            }
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

        isConnecting = true
        Task {
            do {
                try await serverManager.addPlexServer(token: token, resource: resource)
            } catch {
                plexAuthState = .error("Failed to connect: \(error.localizedDescription)")
            }
            isConnecting = false
        }
    }

    private func cancelPlexPolling() {
        plexPollingTask?.cancel()
        plexPollingTask = nil
    }

    // MARK: - Jellyfin Logic

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
                try await serverManager.addJellyfinServer(url: url, username: username, password: password)
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

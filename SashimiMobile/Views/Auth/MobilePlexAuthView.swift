import SwiftUI

// MARK: - Mobile Plex Auth State

enum MobilePlexAuthState: Equatable {
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

// MARK: - Mobile Plex Auth View

struct MobilePlexAuthView: View {
    @EnvironmentObject var serverManager: ServerManager

    @Binding var isConnecting: Bool

    @State private var plexAuthState: MobilePlexAuthState = .idle
    @State private var plexServers: [PlexResource] = []
    @State private var plexAuthToken: String?
    @State private var plexPollingTask: Task<Void, Never>?

    var navigationTitle: String {
        switch plexAuthState {
        case .selectingServer:
            return "Select Server"
        default:
            return "Sign in with Plex"
        }
    }

    var body: some View {
        plexSections
            .onDisappear {
                cancelPlexPolling()
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
}

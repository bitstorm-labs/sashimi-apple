import SwiftUI

// MARK: - Plex Auth State

enum PlexAuthState: Equatable {
    case idle
    case requestingPin
    case waitingForLink(code: String, pinId: Int)
    case authenticated(token: String)
    case selectingServer
    case connecting
    case error(String)

    static func == (lhs: PlexAuthState, rhs: PlexAuthState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.requestingPin, .requestingPin): return true
        case (.waitingForLink(let a, let b), .waitingForLink(let c, let d)): return a == c && b == d
        case (.authenticated(let a), .authenticated(let b)): return a == b
        case (.selectingServer, .selectingServer): return true
        case (.connecting, .connecting): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - Plex Auth View

struct PlexAuthView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var serverManager: ServerManager

    @FocusState private var focusedField: ServerConnectionField?

    @State private var plexAuthState: PlexAuthState = .idle
    @State private var plexServers: [PlexResource] = []
    @State private var plexAuthToken: String?
    @State private var plexPollingTask: Task<Void, Never>?

    var body: some View {
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

            case .connecting:
                ProgressView()
                    .scaleEffect(1.5)
                Text("Connecting to server...")
                    .font(.title3)
                    .foregroundStyle(SashimiTheme.textSecondary)

            case .error(let message):
                plexErrorView(message: message)
            }
        }
        .frame(maxWidth: 600)
        .onDisappear {
            cancelPlexPolling()
        }
    }

    // MARK: - Sign In Button

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

    // MARK: - Waiting For Link View

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

            Text(code.uppercased())
                .font(.system(size: 56, weight: .bold, design: .monospaced))
                .tracking(12)
                .foregroundStyle(SashimiTheme.textPrimary)
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
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

    // MARK: - Server Selection View

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

    // MARK: - Error View

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

        plexAuthState = .connecting

        Task {
            do {
                try await serverManager.addPlexServer(token: token, resource: resource)
                // ServerManager sets isAuthenticated = true, dismiss the auth flow
                dismiss()
            } catch {
                plexAuthState = .error("Failed to connect: \(error.localizedDescription)")
            }
        }
    }

    private func cancelPlexPolling() {
        plexPollingTask?.cancel()
        plexPollingTask = nil
    }
}

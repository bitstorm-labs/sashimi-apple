import Foundation

/// Why a Quick Connect request can't go on.
enum QuickConnectError: Error, Equatable {
    /// The server no longer knows the request: it expires them after 10
    /// minutes and then answers 404.
    case expired
    /// The server has Quick Connect turned off (it answers 401).
    case disabled
}

/// The server calls a Quick Connect sign-in makes, behind a seam so the
/// polling state machine can be tested without a server.
protocol QuickConnectService: Sendable {
    func isEnabled(serverURL: URL) async -> Bool
    func initiate(serverURL: URL) async throws -> QuickConnectResult
    /// Throws `QuickConnectError.expired` once the server has dropped the request.
    func state(serverURL: URL, secret: String) async throws -> QuickConnectResult
    /// Exchanges an approved request for a session and saves it exactly as a
    /// password sign-in would.
    func signIn(serverURL: URL, secret: String) async throws
}

/// Talks to the real server. The code request and polling run on a client of
/// their own, never `JellyfinClient.shared`: the login screen is also the Add
/// Server sheet, and pointing the shared client at a candidate server while
/// a session is live would break that session. Only the final sign-in goes
/// through `SessionManager`, the same way a password sign-in does.
actor LiveQuickConnectService: QuickConnectService {
    static let shared = LiveQuickConnectService()

    /// One client per server, reused across polls: a fresh client per poll
    /// would build (and never invalidate) a URLSession every three seconds.
    private var clients: [URL: JellyfinClient] = [:]

    private func client(for serverURL: URL) async -> JellyfinClient {
        if let client = clients[serverURL] { return client }
        let client = JellyfinClient()
        await client.configure(serverURL: serverURL)
        clients[serverURL] = client
        return client
    }

    func isEnabled(serverURL: URL) async -> Bool {
        await client(for: serverURL).isQuickConnectEnabled()
    }

    func initiate(serverURL: URL) async throws -> QuickConnectResult {
        do {
            return try await client(for: serverURL).initiateQuickConnect()
        } catch {
            throw Self.translate(error)
        }
    }

    func state(serverURL: URL, secret: String) async throws -> QuickConnectResult {
        do {
            return try await client(for: serverURL).quickConnectState(secret: secret)
        } catch {
            throw Self.translate(error)
        }
    }

    func signIn(serverURL: URL, secret: String) async throws {
        try await SessionManager.shared.loginWithQuickConnect(serverURL: serverURL, secret: secret)
    }

    /// 404 = the server has forgotten the request; 401 (surfaced by the
    /// client as `invalidCredentials`) = Quick Connect is switched off.
    static func translate(_ error: Error) -> Error {
        switch error {
        case JellyfinError.httpError(statusCode: 404):
            return QuickConnectError.expired
        case JellyfinError.invalidCredentials:
            return QuickConnectError.disabled
        default:
            return error
        }
    }
}

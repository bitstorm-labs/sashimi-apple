import Foundation

/// Values collected by the saved-server editor. A blank password means that
/// the existing session credential should be retained when the connection
/// identity has not changed.
struct ServerEditRequest: Equatable {
    let nameOverride: String?
    let serverURL: URL
    let username: String
    let password: String?

    init(nameOverride: String?, serverURL: URL, username: String, password: String?) {
        let trimmedAlias = nameOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.nameOverride = trimmedAlias.isEmpty ? nil : trimmedAlias
        self.serverURL = Self.normalize(serverURL) ?? serverURL
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password?.isEmpty == true ? nil : password
    }

    /// Normalizes the same inputs accepted by the sign-in forms, including a
    /// host entered without an explicit scheme.
    static func normalize(_ rawValue: String) -> URL? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    static func normalize(_ url: URL) -> URL? {
        normalize(url.absoluteString)
    }

    func urlChanged(from current: ServerConfig) -> Bool {
        let normalizedCurrent = Self.normalize(current.url) ?? current.url
        return serverURL != normalizedCurrent
    }

    func changesConnection(from current: ServerConfig) -> Bool {
        urlChanged(from: current) || username != current.username || password != nil
    }
}

struct ServerEditAuthentication: Equatable {
    let accessToken: String
    let username: String
    let userId: String
    let serverName: String?
}

struct PreparedServerEdit: Equatable {
    let server: ServerConfig
    let accessToken: String?
}

enum ServerEditCoordinator {
    typealias Authenticator = @Sendable (URL, String, String) async throws -> ServerEditAuthentication

    static func prepare(
        current: ServerConfig,
        request: ServerEditRequest,
        authenticate: @escaping Authenticator
    ) async throws -> PreparedServerEdit {
        guard !request.username.isEmpty else {
            throw SessionError.invalidUsername
        }

        let urlChanged = request.urlChanged(from: current)
        let usernameChanged = request.username != current.username
        let requiresAuthentication = request.changesConnection(from: current)

        if (urlChanged || usernameChanged) && request.password == nil {
            throw SessionError.passwordRequiredForConnectionChange
        }

        guard requiresAuthentication else {
            return PreparedServerEdit(
                server: ServerConfig(
                    id: current.id,
                    name: current.name,
                    url: current.url,
                    username: current.username,
                    userId: current.userId,
                    nameOverride: request.nameOverride
                ),
                accessToken: nil
            )
        }

        guard let password = request.password else {
            throw SessionError.passwordRequiredForConnectionChange
        }
        let authentication = try await authenticate(request.serverURL, request.username, password)
        let authenticatedName = authentication.serverName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackName = request.serverURL.host ?? current.name
        let serverName = authenticatedName.isEmpty
            ? (urlChanged ? fallbackName : current.name)
            : authenticatedName

        let updatedServer = ServerConfig(
            id: current.id,
            name: serverName,
            url: request.serverURL,
            username: authentication.username,
            userId: authentication.userId,
            nameOverride: request.nameOverride
        )
        return PreparedServerEdit(server: updatedServer, accessToken: authentication.accessToken)
    }
}

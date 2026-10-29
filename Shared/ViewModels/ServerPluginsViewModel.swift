import Foundation

/// What Settings › Server Plugins asks the server, as a protocol so the view
/// model's rules are testable without one (the same seam
/// `ServerDashboardClient` uses).
protocol ServerPluginsClient: Sendable {
    func getInstalledPlugins() async throws -> [InstalledPluginInfo]
    func probePluginRoute(path: String, query: [URLQueryItem]) async -> PluginProbeResult
    func getPublicServerInfo() async throws -> DashboardSystemInfo
}

extension JellyfinClient: ServerPluginsClient {}

enum ServerPluginsState: Equatable {
    case idle
    case loading
    case loaded(ServerPluginsReport)
    /// The server couldn't be asked. Shown as an error row with Retry, never
    /// as "not installed": an unreachable server says nothing about plugins.
    case failed
}

/// Settings › Server Plugins, shared by tvOS and iOS. Settings owns one and
/// loads it when it opens (for the row's "5 of 5 found" subtitle); the
/// detail screen reuses it and adds Refresh. No polling.
@MainActor
final class ServerPluginsViewModel: ObservableObject {
    @Published private(set) var state: ServerPluginsState = .idle

    private let client: ServerPluginsClient
    /// The server the current state describes; a server switch reloads.
    private var loadedKey: String?

    init(client: ServerPluginsClient = JellyfinClient.shared) {
        self.client = client
    }

    /// Loads once per server: reopening Settings doesn't ask again, a server
    /// switch (a new `key`) or an earlier failure does.
    func loadIfNeeded(key: String, isAdministrator: Bool, fallbackServerName: String) async {
        if loadedKey == key, case .loaded = state { return }
        if loadedKey == key, state == .loading { return }
        await refresh(key: key, isAdministrator: isAdministrator, fallbackServerName: fallbackServerName)
    }

    func refresh(key: String, isAdministrator: Bool, fallbackServerName: String) async {
        loadedKey = key
        state = .loading
        let info = try? await client.getPublicServerInfo()
        let name = info?.serverName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackServerName

        let rows: [ServerPluginRow]?
        var asAdmin = isAdministrator
        if isAdministrator {
            do {
                rows = ServerPluginCatalog.adminRows(installed: try await client.getInstalledPlugins())
            } catch JellyfinError.httpError(statusCode: 403) {
                // The admin flag was stale (rights removed since sign-in):
                // probe like any other user instead of failing.
                asAdmin = false
                rows = await probedRows()
            } catch {
                rows = nil
            }
        } else {
            rows = await probedRows()
        }

        // A Refresh started for another server meanwhile owns the state now.
        guard loadedKey == key else { return }
        guard let rows else {
            state = .failed
            return
        }
        state = .loaded(ServerPluginsReport(
            isAdministrator: asAdmin, serverName: name, serverVersion: info?.version, rows: rows
        ))
    }

    /// Probes every plugin that has a route, in parallel; nil if any probe
    /// failed, so a flaky network can't masquerade as "not detected".
    private func probedRows() async -> [ServerPluginRow]? {
        let client = client
        var results: [SashimiPlugin: PluginProbeResult] = [:]
        await withTaskGroup(of: (SashimiPlugin, PluginProbeResult).self) { group in
            for plugin in SashimiPlugin.allCases {
                guard let probe = plugin.probe else { continue }
                group.addTask { (plugin, await client.probePluginRoute(path: probe.path, query: probe.query)) }
            }
            for await (plugin, result) in group { results[plugin] = result }
        }
        if results.values.contains(.failed) { return nil }
        return ServerPluginCatalog.probedRows(results: results)
    }

    /// The Settings row subtitle.
    func subtitle(fallbackServerName: String) -> String {
        switch state {
        case .idle, .loading: return "Checking \(fallbackServerName)…"
        case .failed: return "Couldn't check \(fallbackServerName)"
        case .loaded(let report): return ServerPluginCatalog.summary(for: report)
        }
    }
}

extension ServerPluginsViewModel {
    /// Settings' entry points: the session decides which server and whether
    /// the admin `/Plugins` path applies.
    func loadIfNeeded(for session: SessionManager) async {
        await loadIfNeeded(
            key: Self.key(for: session),
            isAdministrator: session.isAdministrator,
            fallbackServerName: Self.serverName(for: session)
        )
    }

    func refresh(for session: SessionManager) async {
        await refresh(
            key: Self.key(for: session),
            isAdministrator: session.isAdministrator,
            fallbackServerName: Self.serverName(for: session)
        )
    }

    func subtitle(for session: SessionManager) -> String {
        subtitle(fallbackServerName: Self.serverName(for: session))
    }

    static func serverName(for session: SessionManager) -> String {
        session.activeServer?.displayName ?? "your server"
    }

    /// Server, user and admin flag: a change in any of them changes the answer.
    static func key(for session: SessionManager) -> String {
        "\(session.activeServerId ?? "")|\(session.currentUser?.id ?? "")|\(session.isAdministrator)"
    }
}

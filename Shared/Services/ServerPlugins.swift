import Foundation

/// A server plugin Sashimi uses. Every one is optional: the app keeps a
/// fallback for each, and Settings › Server Plugins only explains what the
/// connected server has.
enum SashimiPlugin: String, CaseIterable, Identifiable, Sendable {
    case lists
    case channels
    case continueWatching
    case themeSongs
    case skipSegments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lists: return "Sashimi Lists"
        case .channels: return "Channels"
        case .continueWatching: return "Continue Watching"
        case .themeSongs: return "Theme Songs"
        case .skipSegments: return "Skip segments"
        }
    }

    /// The Sashimi feature it powers, shown while it works.
    var purpose: String {
        switch self {
        case .lists: return "Shared lists and list owners"
        case .channels: return "SashimiTV channels and the guide"
        case .continueWatching: return "Server-ranked Continue Watching, Remove from row"
        case .themeSongs: return "Theme music on show and movie pages"
        case .skipSegments: return "Skip Intro / Skip Credits buttons"
        }
    }

    /// What the app loses without it; `ServerPluginCatalog.detail` finishes the
    /// sentence with why ("until this is installed").
    var lossWithout: String {
        switch self {
        case .lists: return "Shared lists won't show who owns them"
        case .channels: return "SashimiTV channels won't appear"
        case .continueWatching: return "Continue Watching falls back to the app's own order"
        case .themeSongs: return "Show and movie pages stay silent"
        case .skipSegments: return "Skip Intro and Skip Credits won't appear"
        }
    }

    /// The plugin(s) that provide it, by install GUID (dashless, as the live
    /// server returns them) with the name as a fallback match. Skip segments
    /// come from Jellyfin's native `/MediaSegments`, which any of three
    /// providers can fill.
    var providers: [PluginProvider] {
        switch self {
        case .lists: return [PluginProvider(name: "Sashimi Lists", guid: "d95b448462cb487392c566a65b86b420")]
        case .channels: return [PluginProvider(name: "Channels", guid: "7a3f1c925d644b089f216c8e5b0a4d73")]
        case .continueWatching: return [PluginProvider(name: "Continue Watching", guid: "a286cbd2ce2246adad0fd49491cce52a")]
        case .themeSongs: return [PluginProvider(name: "Theme Songs", guid: "d8d1d1a14d9e4d559a2e0a0a1f5b7c31")]
        case .skipSegments:
            return [
                PluginProvider(name: "Intro Skipper", guid: "c83d86bba1e04c35a113e2101cf4ee6b"),
                PluginProvider(name: "TheIntroDB", guid: "c9e41b9563e445e29db6b83df21ae5e7"),
                PluginProvider(name: "Segment Editor", guid: "ace21d44a4e54a85ae75acd2e24a9574")
            ]
        }
    }

    /// The plugin's own route a non-admin can call, since `/Plugins` needs an
    /// administrator. Read from the plugin repos: all three are `[Authorize]`
    /// (any signed-in user). `/SashimiLists/Owners` with no ids answers `{}`;
    /// `/ContinueWatching` with no userId means the caller's own row. Theme
    /// Songs and the segment providers have no such route, so nil.
    var probe: (path: String, query: [URLQueryItem])? {
        switch self {
        case .lists: return ("/SashimiLists/Owners", [])
        case .channels: return ("/VirtualChannels", [])
        case .continueWatching: return ("/ContinueWatching", [URLQueryItem(name: "limit", value: "1")])
        case .themeSongs, .skipSegments: return nil
        }
    }
}

struct PluginProvider: Equatable, Sendable {
    let name: String
    let guid: String
}

/// The badge on a plugin row: "● Active", "▲ Restart needed", "○ Not detected".
enum PluginRowBadge: Equatable, Sendable {
    /// Admin: installed, with Jellyfin's status.
    case status(ServerPluginStatus)
    /// Admin, skip segments: this many providers are active.
    case providers(Int)
    case notInstalled
    /// Non-admin probe results.
    case detected
    case notDetected
    /// Non-admin, and the plugin has no route to probe.
    case adminOnly

    var label: String {
        switch self {
        case .status(let status):
            switch status {
            case .active: return "Active"
            case .restart: return "Restart needed"
            case .deleted: return "Removed on restart"
            case .disabled: return "Disabled"
            case .notSupported: return "Not supported"
            case .malfunctioned: return "Failed to load"
            case .superseded: return "Superseded"
            case .unknown(let raw): return raw.isEmpty ? "Unknown" : raw
            }
        case .providers(let count): return count == 1 ? "1 provider" : "\(count) providers"
        case .notInstalled: return "Not installed"
        case .detected: return "Detected"
        case .notDetected: return "Not detected"
        case .adminOnly: return "Only an admin can check this"
        }
    }

    var tone: DashboardTone {
        switch self {
        case .status(let status):
            switch status {
            case .active: return .ok
            case .restart, .deleted, .disabled: return .warning
            case .notSupported, .malfunctioned: return .failure
            case .superseded, .unknown: return .neutral
            }
        case .providers, .detected: return .ok
        case .notInstalled, .notDetected, .adminOnly: return .neutral
        }
    }

    /// SF Symbol drawn in the tone's colour, matching the mockup's ● ▲ ✕ ○ –.
    var symbolName: String {
        switch self {
        case .adminOnly: return "minus.circle"
        case .notInstalled, .notDetected: return "circle"
        default:
            switch tone {
            case .warning: return "exclamationmark.triangle.fill"
            case .failure: return "xmark.circle.fill"
            default: return "circle.fill"
            }
        }
    }

    /// Rows a person should do something about; counted in the summary.
    var needsAttention: Bool { tone.needsAttention }

    /// The plugin is on the server (whatever its state).
    var isPresent: Bool {
        switch self {
        case .status, .providers, .detected: return true
        case .notInstalled, .notDetected, .adminOnly: return false
        }
    }
}

struct ServerPluginRow: Identifiable, Equatable, Sendable {
    let plugin: SashimiPlugin
    /// Admin only; nil shows as "—" for a missing plugin and nothing otherwise.
    let version: String?
    let badge: PluginRowBadge
    /// What it powers, or, when it doesn't work, what breaks and why.
    let detail: String
    /// Skip segments: "Intro Skipper 12.0.6 · TheIntroDB 1.3.0".
    let providerLine: String?

    var id: String { plugin.id }
}

/// Everything the Server Plugins screen shows for one server.
struct ServerPluginsReport: Equatable, Sendable {
    let isAdministrator: Bool
    let serverName: String
    let serverVersion: String?
    let rows: [ServerPluginRow]

    /// "popcorn · Jellyfin 12.4.0"
    var serverLine: String {
        guard let serverVersion, !serverVersion.isEmpty else { return serverName }
        return "\(serverName) · Jellyfin \(serverVersion)"
    }
}

/// The pure rules behind Settings › Server Plugins, kept apart from the view
/// model so they are testable without a server.
enum ServerPluginCatalog {
    /// Lower-case hex with dashes and braces removed, so the dashed and
    /// dashless forms of the same GUID compare equal.
    static func normalizedGUID(_ guid: String) -> String {
        guid.lowercased().filter { $0.isHexDigit }
    }

    private static func normalizedName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The server's entry for a provider: by GUID, else by name. When a plugin
    /// is listed twice (an update leaves the old one "Superceded" until the
    /// restart) the most useful status wins.
    static func match(_ provider: PluginProvider, in installed: [InstalledPluginInfo]) -> InstalledPluginInfo? {
        let guid = normalizedGUID(provider.guid)
        var candidates = installed.filter { $0.id.map(normalizedGUID) == guid }
        if candidates.isEmpty {
            let name = normalizedName(provider.name)
            candidates = installed.filter { $0.name.map(normalizedName) == name }
        }
        return candidates.min { rank($0.status) < rank($1.status) }
    }

    private static func rank(_ status: ServerPluginStatus) -> Int {
        switch status {
        case .active: return 0
        case .restart: return 1
        case .disabled: return 2
        case .notSupported: return 3
        case .malfunctioned: return 4
        case .deleted: return 5
        case .unknown: return 6
        case .superseded: return 7
        }
    }

    /// The row text under the name: the purpose while it works, otherwise what
    /// the app loses and what it's waiting on.
    static func detail(for plugin: SashimiPlugin, badge: PluginRowBadge) -> String {
        let loss = plugin.lossWithout
        switch badge {
        case .notInstalled, .notDetected: return "\(loss) until this is installed"
        case .status(.restart): return "\(loss) until Jellyfin restarts"
        case .status(.malfunctioned): return "\(loss): Jellyfin couldn't load it"
        case .status(.notSupported): return "\(loss): it doesn't support this Jellyfin version"
        case .status(.disabled): return "\(loss) while it's disabled"
        case .status(.deleted): return "\(loss) after the next restart"
        default: return plugin.purpose
        }
    }

    /// Admin rows from `GET /Plugins`.
    static func adminRows(installed: [InstalledPluginInfo]) -> [ServerPluginRow] {
        SashimiPlugin.allCases.map { plugin in
            if plugin == .skipSegments {
                return skipSegmentsRow(installed: installed)
            }
            guard let provider = plugin.providers.first, let found = match(provider, in: installed) else {
                return ServerPluginRow(
                    plugin: plugin, version: nil, badge: .notInstalled,
                    detail: detail(for: plugin, badge: .notInstalled), providerLine: nil
                )
            }
            let badge = PluginRowBadge.status(found.status)
            return ServerPluginRow(
                plugin: plugin, version: found.version, badge: badge,
                detail: detail(for: plugin, badge: badge), providerLine: nil
            )
        }
    }

    /// Skip segments counts as installed if any provider is. Its badge counts
    /// the active ones; with none active it takes the best provider's status.
    static func skipSegmentsRow(installed: [InstalledPluginInfo]) -> ServerPluginRow {
        let plugin = SashimiPlugin.skipSegments
        let found = plugin.providers.compactMap { provider in
            match(provider, in: installed).map { (provider: provider, info: $0) }
        }
        let line = found.isEmpty ? nil : found
            .map { [$0.provider.name, $0.info.version].compactMap { $0 }.joined(separator: " ") }
            .joined(separator: " · ")
        let activeCount = found.filter { $0.info.status == .active }.count
        let badge: PluginRowBadge
        if activeCount > 0 {
            badge = .providers(activeCount)
        } else if let best = found.map(\.info).min(by: { rank($0.status) < rank($1.status) }) {
            badge = .status(best.status)
        } else {
            badge = .notInstalled
        }
        return ServerPluginRow(
            plugin: plugin, version: nil, badge: badge,
            detail: detail(for: plugin, badge: badge), providerLine: line
        )
    }

    /// Non-admin rows from the route probes; plugins without a probe say only
    /// an admin can check them.
    static func probedRows(results: [SashimiPlugin: PluginProbeResult]) -> [ServerPluginRow] {
        SashimiPlugin.allCases.map { plugin in
            let badge: PluginRowBadge
            switch results[plugin] {
            case .detected: badge = .detected
            case .notDetected: badge = .notDetected
            case .failed, nil: badge = .adminOnly
            }
            return ServerPluginRow(
                plugin: plugin, version: nil, badge: badge,
                detail: detail(for: plugin, badge: badge), providerLine: nil
            )
        }
    }

    /// The Settings row subtitle: "5 of 5 found on popcorn".
    static func summary(for report: ServerPluginsReport) -> String {
        let checkable = report.rows.filter { $0.badge != .adminOnly }
        let found = checkable.filter { $0.badge.isPresent }.count
        let verb = report.isAdministrator ? "found" : "detected"
        var text = "\(found) of \(checkable.count) \(verb) on \(report.serverName)"
        let attention = report.rows.filter { $0.badge.needsAttention }.count
        if attention > 0 {
            text += attention == 1 ? " · 1 needs attention" : " · \(attention) need attention"
        }
        return text
    }
}

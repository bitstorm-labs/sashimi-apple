import Foundation

/// One entry of Jellyfin's admin-only `GET /Plugins`.
struct InstalledPluginInfo: Decodable, Equatable, Sendable {
    let name: String?
    let version: String?
    let status: ServerPluginStatus
    /// The plugin's GUID as the server wrote it. Jellyfin serialises GUIDs
    /// dashless ("N" format), but older servers and some proxies hand back the
    /// dashed form, so compare through `ServerPluginCatalog.normalizedGUID`.
    let id: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case version = "Version"
        case status = "Status"
        case id = "Id"
    }

    init(name: String?, version: String?, status: ServerPluginStatus, id: String?) {
        self.name = name
        self.version = version
        self.status = status
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        status = (try? container.decodeIfPresent(ServerPluginStatus.self, forKey: .status)) ?? .unknown("")
    }
}

/// Jellyfin's `PluginStatus`. The server writes the enum's name; the numeric
/// form is accepted too because a server without the string-enum converter
/// sends the raw value instead.
enum ServerPluginStatus: Equatable, Sendable, Decodable {
    case active
    case restart
    case deleted
    case disabled
    case notSupported
    case malfunctioned
    /// Jellyfin keeps the old version of an updated plugin listed as
    /// "Superceded" (its spelling) until the next restart.
    case superseded
    case unknown(String)

    init(rawName: String) {
        switch rawName.lowercased() {
        case "active": self = .active
        case "restart": self = .restart
        case "deleted": self = .deleted
        case "disabled": self = .disabled
        case "notsupported": self = .notSupported
        case "malfunctioned": self = .malfunctioned
        case "superceded", "superseded": self = .superseded
        default: self = .unknown(rawName)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            self.init(rawName: name)
            return
        }
        let order = ["Active", "Restart", "Deleted", "Disabled", "NotSupported", "Malfunctioned", "Superceded"]
        let raw = try container.decode(Int.self)
        self.init(rawName: order.indices.contains(raw) ? order[raw] : "\(raw)")
    }
}

/// What a non-admin probe of a plugin's own route found.
enum PluginProbeResult: Equatable, Sendable {
    /// The route answered (2xx), or refused us (403): either way it exists.
    case detected
    /// 404: nothing on the server owns the route.
    case notDetected
    /// The server couldn't be reached or failed; says nothing about the plugin.
    case failed
}

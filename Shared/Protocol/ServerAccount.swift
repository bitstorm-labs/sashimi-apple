import Foundation

enum ServerType: String, Codable {
    case jellyfin, plex
}

struct ServerAccount: Codable, Identifiable, Hashable {
    let id: String
    let serverType: ServerType
    let serverURL: URL
    let serverName: String
    let userId: String
    let userName: String
    var accessToken: String

    static func == (lhs: ServerAccount, rhs: ServerAccount) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

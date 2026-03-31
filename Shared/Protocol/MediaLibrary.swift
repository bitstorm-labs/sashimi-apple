import Foundation

enum LibraryType: String, Codable {
    case movies, tvShows, music, other
}

struct MediaLibrary: Identifiable, Hashable {
    let id: String
    let serverId: String
    let rawId: String
    let name: String
    let type: LibraryType
}

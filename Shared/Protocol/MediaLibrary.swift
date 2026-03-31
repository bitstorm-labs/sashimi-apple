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
    let collectionType: String?  // Raw server value (e.g. "tvshows", "movies") for filtering

    init(id: String, serverId: String, rawId: String, name: String, type: LibraryType, collectionType: String? = nil) {
        self.id = id
        self.serverId = serverId
        self.rawId = rawId
        self.name = name
        self.type = type
        self.collectionType = collectionType
    }
}

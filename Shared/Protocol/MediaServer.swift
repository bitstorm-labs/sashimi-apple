import Foundation

enum ImageType: String {
    case primary = "Primary"
    case backdrop = "Backdrop"
    case thumb = "Thumb"
}

enum PlaybackQuality: String, CaseIterable {
    case auto
    case quality1080p
    case quality720p
    case quality480p

    var maxBitrate: Int? {
        switch self {
        case .auto: return nil
        case .quality1080p: return 20_000_000
        case .quality720p: return 8_000_000
        case .quality480p: return 4_000_000
        }
    }
}

protocol MediaServer: AnyObject, Sendable {
    var id: String { get }
    var name: String { get }
    var serverType: ServerType { get }
    var serverURL: URL { get }

    func getLibraries() async throws -> [MediaLibrary]
    func getResumeItems(limit: Int) async throws -> [MediaItem]
    func getNextUp(limit: Int) async throws -> [MediaItem]
    func getLatestMedia(libraryId: String?, limit: Int) async throws -> [MediaItem]
    func getItem(id: String) async throws -> MediaItem
    func getChildren(parentId: String, type: MediaItemType?, sortBy: String, sortOrder: String, limit: Int, startIndex: Int) async throws -> (items: [MediaItem], totalCount: Int)
    func getSeasons(seriesId: String) async throws -> [MediaItem]
    func getEpisodes(seriesId: String, seasonId: String?) async throws -> [MediaItem]
    func search(query: String, limit: Int) async throws -> [MediaItem]

    func getStreamInfo(itemId: String, quality: PlaybackQuality) async throws -> StreamInfo
    func reportPlaybackStart(itemId: String, positionSeconds: Double) async throws
    func reportPlaybackProgress(itemId: String, positionSeconds: Double, isPaused: Bool) async throws
    func reportPlaybackStopped(itemId: String, positionSeconds: Double) async throws

    func markPlayed(itemId: String) async throws
    func markUnplayed(itemId: String) async throws
    func setFavorite(itemId: String, isFavorite: Bool) async throws
    func deleteItem(itemId: String) async throws
    func refreshMetadata(itemId: String) async throws

    func imageURL(itemId: String, type: ImageType, maxWidth: Int) -> URL?
    func userImageURL(maxWidth: Int) -> URL?
}

extension MediaServer {
    func deleteItem(itemId: String) async throws {}
    func refreshMetadata(itemId: String) async throws {}
    func userImageURL(maxWidth: Int) -> URL? { nil }
}

import SwiftUI
import SwiftData
import UIKit

// MARK: - Entries

/// One completed download, copied out of SwiftData as plain values so the
/// offline screens never hold live model objects across a reload.
struct OfflineEntry: Identifiable, Equatable {
    let recordID: String
    let itemId: String
    let serverID: String?
    let name: String
    let itemType: ItemType
    let seriesId: String?
    let seriesName: String?
    let seasonId: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let overview: String?
    let runTimeTicks: Int64?
    let productionYear: Int?
    let positionTicks: Int64
    /// A position saved offline that the server has not heard about yet.
    let needsSync: Bool
    let dateCompleted: Date?

    var id: String { recordID }

    init(_ record: DownloadedItem) {
        recordID = record.recordID
        itemId = record.itemId
        serverID = record.serverID
        name = record.name
        itemType = record.itemType
        seriesId = record.seriesId
        seriesName = record.seriesName
        seasonId = record.seasonId
        seasonNumber = record.seasonNumber
        episodeNumber = record.episodeNumber
        overview = record.overview
        runTimeTicks = record.runTimeTicks
        productionYear = record.productionYear
        positionTicks = record.lastPlaybackPositionTicks
        needsSync = record.needsProgressSync
        dateCompleted = record.dateCompleted
    }

    var isPlayed: Bool {
        OfflinePlaybackRules.isPlayed(positionTicks: positionTicks, runTimeTicks: runTimeTicks)
    }

    var isInProgress: Bool {
        OfflinePlaybackRules.isInProgress(positionTicks: positionTicks, runTimeTicks: runTimeTicks)
    }

    /// One show per server: ids are only unique within a Jellyfin server, and
    /// old records may lack a series id.
    var seriesKey: String {
        "\(serverID ?? "legacy"):\(seriesId ?? seriesName ?? itemId)"
    }

    var episodeKey: OfflineEpisodeKey {
        OfflineEpisodeKey(
            id: itemId,
            seriesKey: seriesKey,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            isPlayed: isPlayed,
            isInProgress: isInProgress
        )
    }

    /// The item as the player and the shared cards expect it, carrying the
    /// local resume point and watched state.
    var item: BaseItemDto {
        BaseItemDto.offlineItem(
            id: itemId,
            name: name,
            type: itemType,
            seriesName: seriesName,
            seriesId: seriesId,
            seasonId: seasonId,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            overview: overview,
            runTimeTicks: runTimeTicks,
            productionYear: productionYear,
            positionTicks: positionTicks
        )
    }
}

/// The downloaded episodes of one show.
struct OfflineShow: Identifiable, Equatable {
    let id: String
    let name: String
    let seriesId: String?
    let serverID: String?
    /// Season/episode order; episodes that can't be ordered go last.
    let episodes: [OfflineEntry]

    var seasons: [Int] {
        Array(Set(episodes.compactMap(\.seasonNumber))).sorted()
    }

    var unplayedCount: Int {
        episodes.filter { !$0.isPlayed }.count
    }

    var needsSync: Bool {
        episodes.contains(where: \.needsSync)
    }

    var year: Int? {
        episodes.compactMap(\.productionYear).min()
    }

    /// What the show's Play / Resume button starts.
    var playTarget: OfflineEntry? {
        guard let key = OfflineEpisodeOrder.playTarget(in: episodes.map(\.episodeKey)) else {
            return episodes.first
        }
        return episodes.first { $0.itemId == key.id }
    }

    /// A series item for the shared poster card (no server metadata offline).
    var seriesItem: BaseItemDto {
        BaseItemDto.offlineItem(
            id: seriesId ?? id,
            name: name,
            type: .series,
            productionYear: year,
            markPlayed: unplayedCount == 0
        )
    }

    /// A representative episode: its directory holds the series poster.
    var artworkEntry: OfflineEntry? {
        episodes.first
    }
}

/// How a pushed offline show page is addressed (navigation values must be
/// Hashable; the page re-reads the show so it stays current).
struct OfflineShowRoute: Hashable {
    let key: String
}

// MARK: - Library

/// The completed downloads, grouped and ordered for the offline screens.
/// Re-reads the store on `reload()`; the views call it on appear and whenever
/// `DownloadManager.stateVersion` moves (a position saved or synced, a
/// download finished or deleted).
@MainActor
final class OfflineLibrary: ObservableObject {
    /// Most recently downloaded first.
    @Published private(set) var entries: [OfflineEntry] = []

    func reload() {
        guard let container = DownloadManager.shared.modelContainer else {
            entries = []
            return
        }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DownloadedItem>(
            predicate: #Predicate { $0.statusRaw == "completed" },
            sortBy: [SortDescriptor(\.dateCompleted, order: .reverse)]
        )
        let fresh = ((try? context.fetch(descriptor)) ?? []).map(OfflineEntry.init)
        if fresh != entries {
            entries = fresh
        }
    }

    var continueWatching: [OfflineEntry] {
        entries.filter(\.isInProgress)
    }

    var nextUp: [OfflineEntry] {
        let episodes = entries.filter { $0.itemType == .episode }
        return OfflineEpisodeOrder.nextUp(in: episodes.map(\.episodeKey)).compactMap { key in
            episodes.first { $0.itemId == key.id && $0.seriesKey == key.seriesKey }
        }
    }

    var movies: [OfflineEntry] {
        entries.filter { $0.itemType != .episode }
    }

    var shows: [OfflineShow] {
        let episodes = entries.filter { $0.itemType == .episode }
        let grouped = Dictionary(grouping: episodes, by: \.seriesKey)
        return grouped.map { key, episodes in
            let ordered = OfflineEpisodeOrder.sorted(episodes.map(\.episodeKey)).compactMap { orderedKey in
                episodes.first { $0.itemId == orderedKey.id }
            }
            let unordered = episodes.filter { episode in !ordered.contains { $0.itemId == episode.itemId } }
            let first = episodes[0]
            return OfflineShow(
                id: key,
                name: first.seriesName ?? first.name,
                seriesId: first.seriesId,
                serverID: first.serverID,
                episodes: ordered + unordered
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func show(forKey key: String) -> OfflineShow? {
        shows.first { $0.id == key }
    }

    /// The hero rotation: what is in progress, then Next Up, then the latest
    /// downloads; one slide per show, only items with landscape artwork.
    var heroEntries: [OfflineEntry] {
        var seen = Set<String>()
        var slides: [OfflineEntry] = []
        for entry in continueWatching + nextUp + entries {
            let showKey = entry.itemType == .episode ? entry.seriesKey : entry.recordID
            guard seen.insert(showKey).inserted, OfflineArtwork.landscape(for: entry) != nil else { continue }
            slides.append(entry)
            if slides.count == 6 { break }
        }
        return slides
    }
}

// MARK: - Artwork

/// Images saved with each download (poster.jpg, backdrop.jpg and, for
/// episodes, series_poster.jpg), decoded once and cached.
enum OfflineArtwork {
    private static let cache = NSCache<NSString, UIImage>()

    /// Portrait poster: a movie's poster, or the show's for an episode.
    static func poster(for entry: OfflineEntry) -> Image? {
        image(for: entry, files: entry.itemType == .episode ? ["series_poster.jpg", "poster.jpg"] : ["poster.jpg"])
    }

    /// Landscape art: the backdrop, or an episode's own still.
    static func landscape(for entry: OfflineEntry) -> Image? {
        image(for: entry, files: entry.itemType == .episode ? ["backdrop.jpg", "poster.jpg"] : ["backdrop.jpg"])
    }

    /// An episode's still (its Primary image, saved as poster.jpg).
    static func thumbnail(for entry: OfflineEntry) -> Image? {
        image(for: entry, files: ["poster.jpg"])
    }

    private static func image(for entry: OfflineEntry, files: [String]) -> Image? {
        let directory = DownloadFileManager.itemDirectory(for: entry.itemId, serverID: entry.serverID)
        for file in files {
            let path = directory.appendingPathComponent(file).path
            if let cached = cache.object(forKey: path as NSString) {
                return Image(uiImage: cached)
            }
            if let loaded = UIImage(contentsOfFile: path) {
                cache.setObject(loaded, forKey: path as NSString)
                return Image(uiImage: loaded)
            }
        }
        return nil
    }
}

// MARK: - Items for offline playback and display

extension BaseItemDto {
    /// A media item built from what a download stored. The resume point is
    /// dropped once the item counts as played, so it starts over rather than
    /// resuming in the credits. `markPlayed` forces the watched check (a show
    /// whose downloads are all watched).
    static func offlineItem(
        id: String,
        name: String,
        type: ItemType,
        seriesName: String? = nil,
        seriesId: String? = nil,
        seasonId: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        overview: String? = nil,
        runTimeTicks: Int64? = nil,
        productionYear: Int? = nil,
        positionTicks: Int64 = 0,
        markPlayed: Bool = false
    ) -> BaseItemDto {
        let isPlayed = markPlayed
            || OfflinePlaybackRules.isPlayed(positionTicks: positionTicks, runTimeTicks: runTimeTicks)
        let resumeTicks = isPlayed ? 0 : positionTicks
        let userData: UserItemDataDto? = (isPlayed || resumeTicks > 0)
            ? UserItemDataDto(
                playbackPositionTicks: resumeTicks,
                playCount: isPlayed ? 1 : 0,
                isFavorite: false,
                played: isPlayed,
                lastPlayedDate: nil,
                unplayedItemCount: nil
            )
            : nil
        return BaseItemDto(
            id: id, name: name, type: type,
            seriesName: seriesName, seriesId: seriesId, seasonId: seasonId, parentId: nil,
            indexNumber: episodeNumber, parentIndexNumber: seasonNumber,
            overview: overview, runTimeTicks: runTimeTicks, userData: userData,
            imageTags: nil, backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: productionYear,
            communityRating: nil, officialRating: nil, genres: nil, taglines: nil,
            people: nil, criticRating: nil, premiereDate: nil, chapters: nil,
            path: nil, remoteTrailers: nil, localTrailerCount: nil, mediaStreams: nil
        )
    }
}

extension DownloadedItem {
    /// Create a series-type DTO from an episode (for navigating to series detail offline)
    var asSeriesDto: BaseItemDto {
        BaseItemDto.offlineItem(id: seriesId ?? itemId, name: seriesName ?? name, type: .series)
    }

    var asBaseItemDto: BaseItemDto {
        BaseItemDto.offlineItem(
            id: itemId,
            name: name,
            type: itemType,
            seriesName: seriesName,
            seriesId: seriesId,
            seasonId: seasonId,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            overview: overview,
            runTimeTicks: runTimeTicks,
            productionYear: productionYear,
            positionTicks: lastPlaybackPositionTicks
        )
    }
}

// MARK: - Episode navigation for local playback

/// Feeds the shared player the downloaded episodes around the one playing,
/// so a download rolls into the next downloaded episode of its show.
@MainActor
final class DownloadedEpisodeSource: OfflineEpisodeSource {
    private let serverID: String?

    init(serverID: String?) {
        self.serverID = serverID ?? SessionManager.shared.activeServerId
    }

    func adjacentEpisodes(to item: BaseItemDto) -> (previous: BaseItemDto?, next: BaseItemDto?) {
        let show = showEpisodes(for: item)
        let adjacent = OfflineEpisodeOrder.adjacent(to: item.id, in: show.map(\.episodeKey))
        func entry(_ key: OfflineEpisodeKey?) -> BaseItemDto? {
            guard let key else { return nil }
            return show.first { $0.itemId == key.id }?.item
        }
        return (entry(adjacent.previous), entry(adjacent.next))
    }

    func media(for item: BaseItemDto) -> OfflinePlaybackMedia? {
        guard let record = DownloadManager.shared.downloadStatus(for: item.id, serverID: serverID),
              record.isComplete,
              let fileURL = record.videoFileURL else { return nil }
        return OfflinePlaybackMedia(
            item: record.asBaseItemDto,
            fileURL: fileURL,
            subtitles: DownloadManager.shared.offlineSubtitles(for: item.id, serverID: serverID)
        )
    }

    func recordPosition(_ positionTicks: Int64, for item: BaseItemDto) {
        DownloadManager.shared.savePlaybackPosition(itemId: item.id, serverID: serverID, positionTicks: positionTicks)
    }

    /// The completed downloads of `item`'s show on this server.
    private func showEpisodes(for item: BaseItemDto) -> [OfflineEntry] {
        guard let container = DownloadManager.shared.modelContainer else { return [] }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DownloadedItem>(predicate: #Predicate { $0.statusRaw == "completed" })
        let records = (try? context.fetch(descriptor)) ?? []
        return records
            .filter { record in
                record.serverID == serverID
                    && record.itemType == .episode
                    && (item.seriesId.map { record.seriesId == $0 } ?? (record.seriesName == item.seriesName))
            }
            .map(OfflineEntry.init)
    }
}

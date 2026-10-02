import Foundation

/// A downloaded item the player can switch to without the server.
struct OfflinePlaybackMedia {
    /// The item to play. Its `userData` carries the locally saved resume
    /// point (none once it counts as played), which `loadMedia` resumes from.
    let item: BaseItemDto
    let fileURL: URL
    let subtitles: [OfflineSubtitle]
}

/// Episode navigation over downloads, for local-file playback. The iOS app
/// supplies one backed by its downloads; tvOS has none, so local playback
/// there (and anywhere this is nil) keeps the old no-navigation behavior.
@MainActor
protocol OfflineEpisodeSource: AnyObject {
    /// The downloaded episodes either side of `item` in its series.
    func adjacentEpisodes(to item: BaseItemDto) -> (previous: BaseItemDto?, next: BaseItemDto?)
    /// The local file, subtitles and resume point for `item`, if downloaded.
    func media(for item: BaseItemDto) -> OfflinePlaybackMedia?
    /// Saves where playback of `item` got to (synced to the server later).
    func recordPosition(_ positionTicks: Int64, for item: BaseItemDto)
}

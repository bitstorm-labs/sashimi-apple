import Foundation

/// A subtitle track that was downloaded alongside its media.
///
/// Lives in Shared so `PlayerViewModel` can present downloaded subtitles
/// without depending on the iOS-only download store: the app target builds
/// these from its SwiftData records and injects them into `loadMedia`.
struct OfflineSubtitle: Identifiable, Hashable {
    var id: Int { index }

    /// The stream index this track had on the server, reused as the menu id so
    /// selection behaves the same online and offline.
    let index: Int
    let language: String
    let displayTitle: String
    let fileURL: URL
}

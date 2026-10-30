import Foundation

/// The audio and subtitle picks a viewer made for an item, kept after its
/// player is torn down so reopening the same item puts them back.
///
/// The player keeps its picks only for as long as it lives
/// (`sessionSubtitlePreference` / `sessionAudioPreference`). Leaving the app
/// stops playback and drops the player, and the Settings preference that takes
/// over on the next open is only a language: it never burns in an image
/// subtitle, cannot tell "English (SDH)" from "English", and knows nothing of
/// an audio pick. So subtitles came back off (or on a different track) after
/// switching apps.
struct PlaybackTrackMemory {
    struct Subtitle: Codable, Equatable {
        let language: String?
        let displayTitle: String?
        let isExternal: Bool
    }

    struct Audio: Codable, Equatable {
        let language: String?
        let displayName: String
    }

    struct Entry: Codable, Equatable {
        let subtitle: Subtitle?
        let audio: Audio?
        let savedAt: Date
    }

    /// Long enough to cover leaving the app for an evening; short enough that
    /// a later change to the Settings preference still decides tomorrow.
    static let lifetime: TimeInterval = 12 * 60 * 60
    /// Items and series remembered at once; the oldest goes first.
    static let capacity = 20
    static let defaultsKey = "playback.trackMemory"

    static var shared: PlaybackTrackMemory { PlaybackTrackMemory() }

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// Records the picks in force when an item's player goes away, for the
    /// item and, for an episode, its series (#818): the next episode started
    /// from the season page is a different item, and per-item memory alone
    /// brought it back with subtitles off. A session that ended with no pick
    /// is recorded too, so turning subtitles off sticks the same way.
    func remember(itemID: String, seriesID: String? = nil, subtitle: Subtitle?, audio: Audio?) {
        var entries = load()
        let entry = Entry(subtitle: subtitle, audio: audio, savedAt: now())
        entries[itemID] = entry
        if let seriesID {
            entries[Self.seriesKey(seriesID)] = entry
        }
        save(entries)
    }

    /// The most recent picks for the item or its series, if recent enough.
    /// Nil when the most recent record holds no pick at all: the viewer
    /// turned them off, and the Settings preference decides.
    func recall(itemID: String, seriesID: String? = nil) -> Entry? {
        let entries = load()
        let candidates = [entries[itemID], seriesID.flatMap { entries[Self.seriesKey($0)] }]
            .compactMap { $0 }
            .filter { now().timeIntervalSince($0.savedAt) < Self.lifetime }
        guard let latest = candidates.max(by: { $0.savedAt < $1.savedAt }),
              latest.subtitle != nil || latest.audio != nil else { return nil }
        return latest
    }

    /// Series share the dictionary with items; Jellyfin ids never contain ":".
    private static func seriesKey(_ seriesID: String) -> String { "series:\(seriesID)" }

    private func load() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }

    private func save(_ entries: [String: Entry]) {
        let current = now()
        let kept = entries
            .filter { current.timeIntervalSince($0.value.savedAt) < Self.lifetime }
            .sorted { $0.value.savedAt > $1.value.savedAt }
            .prefix(Self.capacity)
        let trimmed = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(trimmed) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

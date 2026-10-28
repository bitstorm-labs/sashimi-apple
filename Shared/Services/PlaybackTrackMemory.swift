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
    /// Items remembered at once; the oldest goes first.
    static let capacity = 20
    static let defaultsKey = "playback.trackMemory"

    static var shared: PlaybackTrackMemory { PlaybackTrackMemory() }

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// Records the picks in force when an item's player goes away. With no
    /// pick at all the item is forgotten, so a choice the viewer has since
    /// undone (subtitles turned off) cannot come back.
    func remember(itemID: String, subtitle: Subtitle?, audio: Audio?) {
        var entries = load()
        if subtitle == nil && audio == nil {
            entries[itemID] = nil
        } else {
            entries[itemID] = Entry(subtitle: subtitle, audio: audio, savedAt: now())
        }
        save(entries)
    }

    /// The picks remembered for an item, if they are recent enough.
    func recall(itemID: String) -> Entry? {
        guard let entry = load()[itemID], now().timeIntervalSince(entry.savedAt) < Self.lifetime else { return nil }
        return entry
    }

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

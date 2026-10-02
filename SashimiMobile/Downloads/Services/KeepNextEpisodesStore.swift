import Foundation

/// One show's "Keep next episodes downloaded" setting.
struct KeepNextEpisodesSetting: Codable, Equatable {
    let serverID: String
    let seriesId: String
    var count: Int
    /// Quality used for the episodes this setting queues.
    var qualityRaw: String

    var quality: DownloadQuality {
        DownloadQuality(rawValue: qualityRaw) ?? .high
    }
}

/// The per-show "Keep next episodes downloaded" settings, keyed by server and
/// series and persisted as one JSON blob in UserDefaults. Not SwiftData: the
/// setting outlives the show's downloads and needs no migration.
@MainActor
final class KeepNextEpisodesStore: ObservableObject {
    static let shared = KeepNextEpisodesStore()

    static let defaultsKey = "keepNextEpisodesSettings"

    @Published private(set) var settings: [String: KeepNextEpisodesSetting] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: KeepNextEpisodesSetting].self, from: data) {
            settings = decoded
        }
    }

    static func key(serverID: String, seriesId: String) -> String {
        "\(serverID)|\(seriesId)"
    }

    func setting(serverID: String?, seriesId: String) -> KeepNextEpisodesSetting? {
        guard let serverID else { return nil }
        return settings[Self.key(serverID: serverID, seriesId: seriesId)]
    }

    /// The kept count for a show, 0 when off.
    func count(serverID: String?, seriesId: String) -> Int {
        setting(serverID: serverID, seriesId: seriesId)?.count ?? 0
    }

    /// Turns the setting on (count > 0) or off (0). Quality is kept from an
    /// existing setting when not given.
    func set(count: Int, quality: DownloadQuality? = nil, serverID: String, seriesId: String) {
        let key = Self.key(serverID: serverID, seriesId: seriesId)
        if count <= 0 {
            settings.removeValue(forKey: key)
        } else {
            let qualityRaw = quality?.rawValue ?? settings[key]?.qualityRaw ?? DownloadQuality.high.rawValue
            settings[key] = KeepNextEpisodesSetting(
                serverID: serverID,
                seriesId: seriesId,
                count: count,
                qualityRaw: qualityRaw
            )
        }
        persist()
    }

    /// Every show with the setting on; turning it off removes the entry.
    var activeSettings: [KeepNextEpisodesSetting] {
        settings.values.sorted { $0.seriesId < $1.seriesId }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

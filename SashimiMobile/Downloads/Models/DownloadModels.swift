import Foundation
import SwiftData

// MARK: - Download Quality

enum DownloadQuality: String, Codable, CaseIterable, Identifiable {
    case original
    case high
    case medium
    case low

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: return "Original"
        case .high: return "High (1080p)"
        case .medium: return "Medium (720p)"
        case .low: return "Low (480p)"
        }
    }

    /// Compact form for row captions ("720p · 1.1 GB").
    var shortLabel: String {
        switch self {
        case .original: return "Original"
        case .high: return "1080p"
        case .medium: return "720p"
        case .low: return "480p"
        }
    }

    var subtitle: String {
        switch self {
        case .original: return "Largest file size"
        case .high: return "Up to 20 Mbps"
        case .medium: return "Up to 8 Mbps"
        case .low: return "Up to 4 Mbps"
        }
    }

    var maxBitrate: Int? {
        switch self {
        case .original: return nil
        case .high: return 20_000_000
        case .medium: return 8_000_000
        case .low: return 4_000_000
        }
    }

    /// Pixel width cap matching displayName. A bitrate alone leaves the server
    /// encoding at native resolution, so "Low (480p)" produced a blocky 4K
    /// file rather than a small 480p one. `.original` is a stream copy, so it
    /// has no cap.
    var maxWidth: Int? {
        switch self {
        case .original: return nil
        case .high: return 1920
        case .medium: return 1280
        case .low: return 854
        }
    }

    /// Pixel height cap, paired with `maxWidth` so a 4:3 or portrait source
    /// is bounded too (the width alone lets a 4:3 "480p" come out 640 tall).
    var maxHeight: Int? {
        switch self {
        case .original: return nil
        case .high: return 1080
        case .medium: return 720
        case .low: return 480
        }
    }

    /// Audio share of the tier's bitrate. Stereo for medium/low (a 5.1 track
    /// on a phone is downmixed anyway, and stereo spends the bits better);
    /// high keeps up to 5.1.
    var audioBitrate: Int? {
        switch self {
        case .original: return nil
        case .high: return 384_000
        case .medium: return 192_000
        case .low: return 128_000
        }
    }

    var audioChannels: Int? {
        switch self {
        case .original: return nil
        case .high: return 6
        case .medium, .low: return 2
        }
    }

    /// The video encoder's target: the tier's total minus the audio share.
    ///
    /// This is the parameter that actually sets the encode bitrate. Jellyfin's
    /// progressive /Videos/{id}/stream endpoint has no MaxStreamingBitrate
    /// parameter (that is a PlaybackInfo/HLS concept), so the old URL carried
    /// no video bitrate at all; the server then fell back to its minimum and
    /// encoded every Medium/Low/High download at `-b:v 1000` (1 kbps) and
    /// 416 px wide. The server still caps this at the source's own bitrate.
    var videoBitrate: Int? {
        guard let maxBitrate, let audioBitrate else { return nil }
        return maxBitrate - audioBitrate
    }

    /// Resolves the quality that should actually be downloaded given whether the
    /// raw source can direct-play on this device. `.original` is only honored
    /// when the source is device-compatible; otherwise it degrades to `.high` so
    /// we never persist an unplayable Original file. All transcoded tiers pass
    /// through unchanged (the `compatible` flag is irrelevant for them).
    static func effectiveQuality(requested: DownloadQuality, sourceIsCompatible: Bool) -> DownloadQuality {
        guard requested == .original else { return requested }
        return sourceIsCompatible ? .original : .high
    }
}

// MARK: - Download Status

enum DownloadStatus: String, Codable {
    case queued
    case preparing
    case downloading
    case completed
    case failed

    /// Reads a stored `statusRaw`. Builds before #179 could pause a download
    /// and stored "paused"; nothing has written it since, and its only action
    /// was "Retry". Such a record reads as `.failed`, which offers exactly
    /// that, instead of `.queued` (the fallback for anything unrecognised),
    /// which would show a download that is not actually running.
    static func fromStored(_ raw: String) -> DownloadStatus {
        if let status = DownloadStatus(rawValue: raw) { return status }
        return raw == legacyPausedRawValue ? .failed : .queued
    }

    static let legacyPausedRawValue = "paused"
}

// MARK: - Downloaded Item

@Model
final class DownloadedItem {
    // Jellyfin item ID. IDs are only unique within a Jellyfin server, so
    // DownloadManager enforces uniqueness using (itemId, serverID).
    var itemId: String
    /// Saved server identity so retries and background assets never fall back
    /// to whichever server happens to be mirrored globally at the time.
    var serverID: String?

    // Item metadata (stored for offline display)
    var name: String
    var seriesName: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var overview: String?
    var itemTypeRaw: String
    var runTimeTicks: Int64?
    var productionYear: Int?

    // Download state
    var statusRaw: String
    var quality: String
    var progress: Double
    var totalBytes: Int64
    var downloadedBytes: Int64
    var errorMessage: String?

    // File paths (relative to a server-qualified Downloads directory).
    var videoFileName: String?
    var posterFileName: String?
    var backdropFileName: String?

    // Parent references for organization
    var seriesId: String?
    var seasonId: String?

    // Offline playback progress (for syncing back to server)
    var lastPlaybackPositionTicks: Int64 = 0
    var needsProgressSync: Bool = false

    // Timestamps
    var dateAdded: Date
    var dateCompleted: Date?

    // Subtitles
    @Relationship(deleteRule: .cascade) var subtitles: [DownloadedSubtitle]

    /// Stable identity for SwiftUI lists when the same item exists on multiple
    /// saved servers. Legacy records keep the "legacy" namespace.
    var recordID: String {
        "\(serverID ?? "legacy"):\(itemId)"
    }

    var status: DownloadStatus {
        get { DownloadStatus.fromStored(statusRaw) }
        set { statusRaw = newValue.rawValue }
    }

    var downloadQuality: DownloadQuality {
        get { DownloadQuality(rawValue: quality) ?? .high }
        set { quality = newValue.rawValue }
    }

    var itemType: ItemType {
        ItemType(rawValue: itemTypeRaw) ?? .unknown
    }

    var displayTitle: String {
        if let seriesName, let seasonNum = seasonNumber, let epNum = episodeNumber {
            return "\(seriesName) S\(seasonNum):E\(epNum)"
        }
        return name
    }

    /// Bytes on disk: the final size once known, else what has arrived.
    var sizeBytes: Int64 {
        totalBytes > 0 ? totalBytes : downloadedBytes
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var isComplete: Bool {
        status == .completed
    }

    var videoFileURL: URL? {
        guard let videoFileName else { return nil }
        return DownloadFileManager.itemDirectory(for: itemId, serverID: serverID)
            .appendingPathComponent(videoFileName)
    }

    init(
        itemId: String,
        name: String,
        itemType: ItemType,
        quality: DownloadQuality,
        serverID: String? = nil,
        seriesName: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        overview: String? = nil,
        runTimeTicks: Int64? = nil,
        productionYear: Int? = nil,
        seriesId: String? = nil,
        seasonId: String? = nil
    ) {
        self.itemId = itemId
        self.serverID = serverID
        self.name = name
        self.itemTypeRaw = itemType.rawValue
        self.quality = quality.rawValue
        self.seriesName = seriesName
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.overview = overview
        self.runTimeTicks = runTimeTicks
        self.productionYear = productionYear
        self.seriesId = seriesId
        self.seasonId = seasonId
        self.statusRaw = DownloadStatus.queued.rawValue
        self.progress = 0
        self.totalBytes = 0
        self.downloadedBytes = 0
        self.lastPlaybackPositionTicks = 0
        self.needsProgressSync = false
        self.dateAdded = Date()
        self.subtitles = []
    }
}

// MARK: - Downloaded Subtitle

@Model
final class DownloadedSubtitle {
    var language: String
    var displayTitle: String
    var subtitleIndex: Int
    var fileName: String

    var item: DownloadedItem?

    init(language: String, displayTitle: String, subtitleIndex: Int, fileName: String) {
        self.language = language
        self.displayTitle = displayTitle
        self.subtitleIndex = subtitleIndex
        self.fileName = fileName
    }
}

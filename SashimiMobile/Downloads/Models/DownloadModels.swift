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
}

// MARK: - Download Status

enum DownloadStatus: String, Codable {
    case queued
    case preparing
    case downloading
    case paused
    case completed
    case failed
}

// MARK: - Downloaded Item

@Model
final class DownloadedItem {
    // Jellyfin item ID
    @Attribute(.unique) var itemId: String

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

    // File paths (relative to Documents/Downloads/{itemId}/)
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

    var status: DownloadStatus {
        get { DownloadStatus(rawValue: statusRaw) ?? .queued }
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

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalBytes > 0 ? totalBytes : downloadedBytes, countStyle: .file)
    }

    var isComplete: Bool {
        status == .completed
    }

    var videoFileURL: URL? {
        guard let videoFileName else { return nil }
        return DownloadFileManager.itemDirectory(for: itemId).appendingPathComponent(videoFileName)
    }

    init(
        itemId: String,
        name: String,
        itemType: ItemType,
        quality: DownloadQuality,
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

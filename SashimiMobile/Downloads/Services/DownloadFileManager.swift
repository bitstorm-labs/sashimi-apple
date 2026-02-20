import Foundation

enum DownloadFileManager {
    // MARK: - Directory Paths

    static var downloadsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    static func itemDirectory(for itemId: String) -> URL {
        downloadsRoot.appendingPathComponent(itemId, isDirectory: true)
    }

    static func subtitlesDirectory(for itemId: String) -> URL {
        itemDirectory(for: itemId).appendingPathComponent("subtitles", isDirectory: true)
    }

    // MARK: - Directory Management

    static func createItemDirectory(for itemId: String) throws {
        let dir = itemDirectory(for: itemId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Exclude from iCloud backup
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDir = dir
        try mutableDir.setResourceValues(resourceValues)
    }

    static func createSubtitlesDirectory(for itemId: String) throws {
        let dir = subtitlesDirectory(for: itemId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func deleteItemDirectory(for itemId: String) throws {
        let dir = itemDirectory(for: itemId)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - File Paths

    static func videoPath(for itemId: String, container: String) -> URL {
        let ext = container.isEmpty ? "mp4" : container
        return itemDirectory(for: itemId).appendingPathComponent("video.\(ext)")
    }

    static func posterPath(for itemId: String) -> URL {
        itemDirectory(for: itemId).appendingPathComponent("poster.jpg")
    }

    static func backdropPath(for itemId: String) -> URL {
        itemDirectory(for: itemId).appendingPathComponent("backdrop.jpg")
    }

    static func subtitlePath(for itemId: String, index: Int, language: String) -> URL {
        subtitlesDirectory(for: itemId).appendingPathComponent("\(index)_\(language).vtt")
    }

    // MARK: - File Operations

    static func moveFile(from source: URL, to destination: URL) throws {
        // Ensure parent directory exists
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // Remove existing file if present
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.moveItem(at: source, to: destination)
    }

    static func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Storage Calculations

    static func totalDownloadsSize() -> Int64 {
        directorySize(at: downloadsRoot)
    }

    static func itemSize(for itemId: String) -> Int64 {
        directorySize(at: itemDirectory(for: itemId))
    }

    static func formattedTotalSize() -> String {
        ByteCountFormatter.string(fromByteCount: totalDownloadsSize(), countStyle: .file)
    }

    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = resourceValues.fileSize else {
                continue
            }
            total += Int64(fileSize)
        }
        return total
    }

    static func availableDiskSpace() -> Int64 {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return 0
        }
        return available
    }

    // MARK: - Cleanup

    static func deleteAllDownloads() throws {
        if FileManager.default.fileExists(atPath: downloadsRoot.path) {
            try FileManager.default.removeItem(at: downloadsRoot)
        }
    }
}

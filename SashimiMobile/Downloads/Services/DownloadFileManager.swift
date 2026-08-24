import Foundation

enum DownloadFileManager {
    // MARK: - Directory Paths

    static var downloadsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    static func itemDirectory(for itemId: String, serverID: String? = nil) -> URL {
        guard let serverID, !serverID.isEmpty else {
            // Preserve the path used by pre-multi-server downloads.
            return downloadsRoot.appendingPathComponent(itemId, isDirectory: true)
        }
        return downloadsRoot
            .appendingPathComponent("server-\(safePathComponent(serverID))", isDirectory: true)
            .appendingPathComponent(itemId, isDirectory: true)
    }

    static func subtitlesDirectory(for itemId: String, serverID: String? = nil) -> URL {
        itemDirectory(for: itemId, serverID: serverID)
            .appendingPathComponent("subtitles", isDirectory: true)
    }

    private static func safePathComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
    }

    // MARK: - Directory Management

    static func createItemDirectory(for itemId: String, serverID: String? = nil) throws {
        let dir = itemDirectory(for: itemId, serverID: serverID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Exclude from iCloud backup
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDir = dir
        try mutableDir.setResourceValues(resourceValues)
    }

    static func createSubtitlesDirectory(for itemId: String, serverID: String? = nil) throws {
        let dir = subtitlesDirectory(for: itemId, serverID: serverID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func deleteItemDirectory(for itemId: String, serverID: String? = nil) throws {
        let dir = itemDirectory(for: itemId, serverID: serverID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Moves a legacy unscoped download into the active server namespace when
    /// an older record is first reused. Existing files remain playable while
    /// new copies from another server get an independent directory.
    static func migrateItemDirectory(itemId: String, to serverID: String) throws -> Bool {
        let legacy = itemDirectory(for: itemId)
        let scoped = itemDirectory(for: itemId, serverID: serverID)
        guard FileManager.default.fileExists(atPath: legacy.path) else {
            // There is no legacy payload to move, so rebinding the record is safe.
            return true
        }
        guard !FileManager.default.fileExists(atPath: scoped.path) else {
            // Do not guess which directory is authoritative when both exist.
            return false
        }
        try FileManager.default.createDirectory(
            at: scoped.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: legacy, to: scoped)
        return true
    }

    // MARK: - File Paths

    static func videoPath(for itemId: String, container: String, serverID: String? = nil) -> URL {
        let ext = container.isEmpty ? "mp4" : container
        return itemDirectory(for: itemId, serverID: serverID).appendingPathComponent("video.\(ext)")
    }

    static func posterPath(for itemId: String, serverID: String? = nil) -> URL {
        itemDirectory(for: itemId, serverID: serverID).appendingPathComponent("poster.jpg")
    }

    static func backdropPath(for itemId: String, serverID: String? = nil) -> URL {
        itemDirectory(for: itemId, serverID: serverID).appendingPathComponent("backdrop.jpg")
    }

    static func subtitlePath(for itemId: String, index: Int, language: String, serverID: String? = nil) -> URL {
        subtitlesDirectory(for: itemId, serverID: serverID)
            .appendingPathComponent("\(index)_\(language).vtt")
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

    static func itemSize(for itemId: String, serverID: String? = nil) -> Int64 {
        directorySize(at: itemDirectory(for: itemId, serverID: serverID))
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

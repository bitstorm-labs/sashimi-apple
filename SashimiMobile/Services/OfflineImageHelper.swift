import UIKit

/// Helper to find locally cached images for offline mode.
/// Downloads save poster.jpg, backdrop.jpg, and series_poster.jpg per item.
enum OfflineImageHelper {
    /// Find a local poster image for an item (checks the item's download directory)
    static func posterURL(for itemId: String, serverID: String? = nil) -> URL? {
        let dir = DownloadFileManager.itemDirectory(for: itemId, serverID: serverID)
        // Try series_poster first (for episodes showing series poster), then poster
        for fileName in ["series_poster.jpg", "poster.jpg"] {
            let path = dir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }
        return nil
    }

    /// Find a local backdrop image for an item
    static func backdropURL(for itemId: String, serverID: String? = nil) -> URL? {
        let path = DownloadFileManager.itemDirectory(for: itemId, serverID: serverID)
            .appendingPathComponent("backdrop.jpg")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Find a local thumbnail for an episode
    static func thumbnailURL(for itemId: String, serverID: String? = nil) -> URL? {
        let path = DownloadFileManager.itemDirectory(for: itemId, serverID: serverID)
            .appendingPathComponent("poster.jpg")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Load a UIImage from local download files (reliable for file:// URLs)
    static func loadImage(
        for itemId: String,
        serverID: String? = nil,
        fileNames: [String] = ["poster.jpg"]
    ) -> UIImage? {
        let dir = DownloadFileManager.itemDirectory(for: itemId, serverID: serverID)
        for fileName in fileNames {
            let path = dir.appendingPathComponent(fileName).path
            if let image = UIImage(contentsOfFile: path) {
                return image
            }
        }
        return nil
    }

    /// Check if we have any downloaded episodes for a series
    static func hasDownloadedContent(for itemId: String, serverID: String? = nil) -> Bool {
        let dir = DownloadFileManager.itemDirectory(for: itemId, serverID: serverID)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("poster.jpg").path)
    }
}

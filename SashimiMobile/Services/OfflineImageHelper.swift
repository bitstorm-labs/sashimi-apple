import UIKit

/// Helper to find locally cached images for offline mode.
/// Downloads save poster.jpg, backdrop.jpg, and series_poster.jpg per item.
enum OfflineImageHelper {
    /// Find a local poster image for an item (checks the item's download directory)
    static func posterURL(for itemId: String) -> URL? {
        let dir = DownloadFileManager.itemDirectory(for: itemId)
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
    static func backdropURL(for itemId: String) -> URL? {
        let path = DownloadFileManager.itemDirectory(for: itemId).appendingPathComponent("backdrop.jpg")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Find a local thumbnail for an episode
    static func thumbnailURL(for itemId: String) -> URL? {
        let path = DownloadFileManager.itemDirectory(for: itemId).appendingPathComponent("poster.jpg")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Load a UIImage from local download files (reliable for file:// URLs)
    static func loadImage(for itemId: String, fileNames: [String] = ["poster.jpg"]) -> UIImage? {
        let dir = DownloadFileManager.itemDirectory(for: itemId)
        for fileName in fileNames {
            let path = dir.appendingPathComponent(fileName).path
            if let image = UIImage(contentsOfFile: path) {
                return image
            }
        }
        return nil
    }

    /// Check if we have any downloaded episodes for a series
    static func hasDownloadedContent(for itemId: String) -> Bool {
        let dir = DownloadFileManager.itemDirectory(for: itemId)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("poster.jpg").path)
    }
}

import TVServices
import Foundation

class ContentProvider: TVTopShelfContentProvider {
    private let appGroupIdentifier = "group.com.mondominator.sashimi"

    override func loadTopShelfContent() async -> TVTopShelfContent? {
        guard let items = loadContinueWatchingItems(), !items.isEmpty else {
            return nil
        }

        let topShelfItems = items.compactMap { item -> TVTopShelfSectionedItem? in
            guard let id = item["id"] as? String,
                  let name = item["name"] as? String,
                  let imageURLString = item["imageURL"] as? String,
                  let imageURL = URL(string: imageURLString) else {
                return nil
            }

            let sectionedItem = TVTopShelfSectionedItem(identifier: id)
            sectionedItem.title = name
            sectionedItem.imageShape = .hdtv  // 16:9 widescreen aspect ratio

            sectionedItem.setImageURL(imageURL, for: .screenScale1x)
            sectionedItem.setImageURL(imageURL, for: .screenScale2x)

            // Set progress bar (0.0 to 1.0)
            if let progress = item["progress"] as? Double, progress > 0 {
                sectionedItem.playbackProgress = progress / 100.0  // Convert from percentage
            }

            // Create play action URL
            if let playURL = URL(string: "sashimi://play/\(id)") {
                sectionedItem.playAction = TVTopShelfAction(url: playURL)
            }

            // Create display action URL
            if let displayURL = URL(string: "sashimi://item/\(id)") {
                sectionedItem.displayAction = TVTopShelfAction(url: displayURL)
            }

            return sectionedItem
        }

        guard !topShelfItems.isEmpty else { return nil }

        let section = TVTopShelfItemCollection(items: topShelfItems)
        section.title = "Continue Watching"

        return TVTopShelfSectionedContent(sections: [section])
    }

    private func loadContinueWatchingItems() -> [[String: Any]]? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return nil
        }
        return defaults.array(forKey: "continueWatchingItems") as? [[String: Any]]
    }
}

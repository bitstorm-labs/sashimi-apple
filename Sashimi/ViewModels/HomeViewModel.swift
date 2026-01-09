import Foundation
import Combine
import TVServices

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var continueWatchingItems: [BaseItemDto] = []
    @Published var recentlyAddedItems: [BaseItemDto] = []
    @Published var heroItems: [BaseItemDto] = []
    @Published var libraries: [JellyfinLibrary] = []
    @Published var isLoading = false
    @Published var error: Error?

    private let client = JellyfinClient.shared
    private let appGroupIdentifier = "group.com.sashimi.app"

    func loadContent() async {
        isLoading = true
        error = nil

        do {
            async let resumeItems = client.getResumeItems()
            async let nextUpItems = client.getNextUp()
            async let latestItems = client.getLatestMedia()
            async let libraryViews = client.getLibraryViews()

            let (resume, nextUp, latest, libs) = try await (resumeItems, nextUpItems, latestItems, libraryViews)

            continueWatchingItems = mergeAndSortContinueItems(resume: resume, nextUp: nextUp)
            recentlyAddedItems = latest
            libraries = libs.filter { isMediaLibrary($0) }

            // Save continue watching items for TopShelf extension
            saveContinueWatchingForTopShelf()

            // Load latest 5 from each library for hero rotation
            await loadHeroItems()
        } catch {
            self.error = error
        }

        isLoading = false
    }

    private func saveContinueWatchingForTopShelf() {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return }

        let items: [[String: Any]] = continueWatchingItems.prefix(10).compactMap { item in
            // Check if parent series has backdrop images (regular shows have it, YouTube doesn't)
            let seriesHasBackdrop = item.parentBackdropImageTags?.isEmpty == false

            // For episodes with backdrops (regular shows), use series backdrop
            // For episodes without backdrops (YouTube), use episode's own thumbnail
            let imageId: String
            let imageType: String

            switch item.type {
            case .episode:
                imageId = seriesHasBackdrop ? (item.seriesId ?? item.id) : item.id
                imageType = seriesHasBackdrop ? "Backdrop" : "Primary"
            case .video:
                imageId = item.id
                imageType = "Primary"
            default:
                imageId = item.id
                imageType = "Backdrop"
            }

            let imageURLString = "\(serverURL)/Items/\(imageId)/Images/\(imageType)?maxWidth=1920"
            guard let imageURL = URL(string: imageURLString) else {
                return nil
            }

            var subtitle = ""
            if item.type == .episode {
                let season = item.parentIndexNumber ?? 1
                let episode = item.indexNumber ?? 1
                subtitle = "S\(season):E\(episode)"
                if let seriesName = item.seriesName {
                    subtitle = "\(seriesName) • \(subtitle)"
                }
            }

            return [
                "id": item.id,
                "name": item.type == .episode ? (item.seriesName ?? item.name) : item.name,
                "subtitle": subtitle,
                "imageURL": imageURL.absoluteString,
                "type": item.type?.rawValue ?? "unknown",
                "progress": item.progressPercent
            ]
        }

        defaults.set(items, forKey: "continueWatchingItems")

        // Notify TopShelf to reload
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private func loadHeroItems() async {
        var allHeroItems: [BaseItemDto] = []

        for library in libraries {
            do {
                let items = try await client.getLatestMedia(parentId: library.id, limit: 5)
                allHeroItems.append(contentsOf: items)
            } catch {
                // Silently ignore hero items loading failures - not critical
            }
        }

        // Shuffle the combined items
        heroItems = allHeroItems.shuffled()
    }

    func refresh() async {
        await loadContent()
    }

    private func mergeAndSortContinueItems(resume: [BaseItemDto], nextUp: [BaseItemDto]) -> [BaseItemDto] {
        // Combine resume and nextUp
        let allItems = resume + nextUp

        // Sort by lastPlayedDate (most recent first)
        let sorted = allItems.sorted { item1, item2 in
            let date1 = parseDate(item1.userData?.lastPlayedDate)
            let date2 = parseDate(item2.userData?.lastPlayedDate)
            switch (date1, date2) {
            case (.some(let d1), .some(let d2)):
                return d1 > d2
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return false
            }
        }

        // Deduplicate: only keep the most recent episode per series (or movie)
        var seenIds = Set<String>()
        var seenSeriesIds = Set<String>()
        var merged: [BaseItemDto] = []

        for item in sorted {
            // Skip if we've already seen this exact item
            guard !seenIds.contains(item.id) else { continue }

            // For episodes, dedupe by series - only keep the most recent episode per series
            if let seriesId = item.seriesId {
                guard !seenSeriesIds.contains(seriesId) else { continue }
                seenSeriesIds.insert(seriesId)
            }

            seenIds.insert(item.id)
            merged.append(item)
        }

        return Array(merged.prefix(20))
    }

    private func parseDate(_ dateString: String?) -> Date? {
        guard let dateString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return date
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }

    private func isMediaLibrary(_ library: JellyfinLibrary) -> Bool {
        guard let collectionType = library.collectionType?.lowercased() else { return true }
        return ["movies", "tvshows", "music", "mixed", "homevideos"].contains(collectionType)
    }
}

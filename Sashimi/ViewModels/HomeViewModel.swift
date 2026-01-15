import Foundation
import Combine
import TVServices

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var continueWatchingItems: [BaseItemDto] = []
    @Published var recentlyAddedItems: [BaseItemDto] = []
    @Published var heroItems: [BaseItemDto] = []
    @Published var heroItemLibraryNames: [String: String] = [:]  // itemId -> libraryName
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
        var libraryNames: [String: String] = [:]

        for library in libraries {
            do {
                let items = try await client.getLatestMedia(parentId: library.id, limit: 5)
                for item in items {
                    libraryNames[item.id] = library.name
                }
                allHeroItems.append(contentsOf: items)
            } catch {
                // Silently ignore hero items loading failures - not critical
            }
        }

        // Shuffle the combined items
        heroItems = allHeroItems.shuffled()
        heroItemLibraryNames = libraryNames
    }

    func refresh() async {
        await loadContent()
    }

    private func mergeAndSortContinueItems(resume: [BaseItemDto], nextUp: [BaseItemDto]) -> [BaseItemDto] {
        // Both APIs return items in correct order:
        // - Resume: sorted by DatePlayed descending (most recently watched first)
        // - NextUp: sorted by series last activity (most recently active series first)
        //
        // Strategy: Interleave based on lastPlayedDate where available,
        // falling back to original API position for NextUp items without dates

        // Tag items with their source and original index for stable sorting
        struct TaggedItem {
            let item: BaseItemDto
            let isResume: Bool
            let originalIndex: Int
        }

        let taggedResume = resume.enumerated().map { TaggedItem(item: $0.element, isResume: true, originalIndex: $0.offset) }
        let taggedNextUp = nextUp.enumerated().map { TaggedItem(item: $0.element, isResume: false, originalIndex: $0.offset) }
        let allTagged = taggedResume + taggedNextUp

        // Sort: items with lastPlayedDate first (by date), then items without (by original order)
        let sorted = allTagged.sorted { a, b in
            let dateA = parseDate(a.item.userData?.lastPlayedDate)
            let dateB = parseDate(b.item.userData?.lastPlayedDate)

            switch (dateA, dateB) {
            case (.some(let d1), .some(let d2)):
                return d1 > d2  // Both have dates: most recent first
            case (.some, .none):
                return true  // Item with date comes before item without
            case (.none, .some):
                return false  // Item without date comes after item with
            case (.none, .none):
                // Neither has date (both NextUp): use original API order
                // Resume items should come first, then NextUp in API order
                if a.isResume != b.isResume {
                    return a.isResume  // Resume before NextUp
                }
                return a.originalIndex < b.originalIndex  // Preserve API order
            }
        }

        // Deduplicate: only keep the most recent episode per series (or movie)
        var seenIds = Set<String>()
        var seenSeriesIds = Set<String>()
        var merged: [BaseItemDto] = []

        for tagged in sorted {
            let item = tagged.item

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

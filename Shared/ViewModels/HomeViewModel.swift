import Foundation
import Combine
import os
#if os(tvOS)
import TVServices
#endif

private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "HomeViewModel")

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var continueWatchingItems: [BaseItemDto] = []
    @Published var continueWatchingLibraryNames: [String: String] = [:]  // itemId -> libraryName
    @Published var recentlyAddedItems: [BaseItemDto] = []
    @Published var heroItems: [BaseItemDto] = []
    @Published var heroItemLibraryNames: [String: String] = [:]  // itemId -> libraryName
    @Published var libraries: [JellyfinLibrary] = []
    @Published var isLoading = false
    @Published var error: Error?

    private let client = JellyfinClient.shared
    private let appGroupIdentifier = "group.com.mondominator.sashimi"

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let dateFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

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

            saveContinueWatchingForTopShelf()
            await loadContinueWatchingLibraryNames()
            await loadHeroItems()
        } catch {
            self.error = error
        }

        isLoading = false
    }

    private func loadContinueWatchingLibraryNames() async {
        var libraryNames: [String: String] = [:]

        let seriesIds = Set(continueWatchingItems.compactMap { item -> String? in
            if item.type == .episode { return item.seriesId }
            return item.id
        })

        // Concurrent, not serial. Continue Watching holds up to 20 items, so
        // this was up to 20 sequential round-trips gating the first render --
        // ~0.9s on a 30ms LAN, ~3.5s at 120ms. Nothing here depends on the
        // previous iteration.
        let resolved = await withTaskGroup(of: (String, String)?.self) { group in
            for seriesId in seriesIds {
                group.addTask { [client] in
                    do {
                        let ancestors = try await client.getItemAncestors(itemId: seriesId)
                        guard let library = ancestors.first(where: { $0.type == .collectionFolder }) else { return nil }
                        return (seriesId, library.name)
                    } catch {
                        // Non-fatal: the row just renders without a library name
                        return nil
                    }
                }
            }
            var out: [String: String] = [:]
            for await result in group {
                if let (seriesId, name) = result { out[seriesId] = name }
            }
            return out
        }

        for item in continueWatchingItems {
            let key = item.type == .episode ? item.seriesId : item.id
            if let key, let name = resolved[key] {
                libraryNames[item.id] = name
            }
        }

        continueWatchingLibraryNames = libraryNames
    }

    private func saveContinueWatchingForTopShelf() {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return }

        let items: [[String: Any]] = continueWatchingItems.prefix(10).compactMap { item in
            let seriesHasBackdrop = item.parentBackdropImageTags?.isEmpty == false
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
            guard let imageURL = URL(string: imageURLString) else { return nil }

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
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }

    /// One library's latest-media result, tagged with its position so the
    /// concurrent fetches can be put back into the original library order.
    private struct LibraryLatest {
        let index: Int
        let items: [BaseItemDto]
    }

    private func loadHeroItems() async {
        var allHeroItems: [BaseItemDto] = []
        var libraryNames: [String: String] = [:]

        // Concurrent, but collected in the ORIGINAL library order: the hero
        // rotation should not reorder itself based on which server response
        // happened to land first.
        let perLibrary = await withTaskGroup(of: LibraryLatest?.self) { group in
            for (index, library) in libraries.enumerated() {
                group.addTask { [client] in
                    do {
                        let items = try await client.getLatestMedia(parentId: library.id, limit: 10)
                        return LibraryLatest(index: index, items: items)
                    } catch {
                        // Non-fatal: this library is just missing from the rotation
                        return nil
                    }
                }
            }
            var out: [LibraryLatest] = []
            for await result in group {
                if let result { out.append(result) }
            }
            return out.sorted { $0.index < $1.index }
        }

        for entry in perLibrary {
            let library = libraries[entry.index]
            for item in entry.items {
                libraryNames[item.id] = library.name
            }
            allHeroItems.append(contentsOf: entry.items.prefix(5))
        }

        // Shuffled only on the FIRST load. Reshuffling on every refresh
        // republished a reordered array while the view's currentIndex stayed
        // put, so the hero cut to an unrelated title every 30 seconds,
        // off-cadence from its own 6-second rotation -- and the .id(currentItem.id)
        // change tore down and re-downloaded the backdrop each time.
        if heroItems.isEmpty {
            heroItems = allHeroItems.shuffled()
        } else {
            heroItems = allHeroItems
        }
        heroItemLibraryNames = libraryNames
    }

    func refresh() async {
        await loadContent()
    }

    private func mergeAndSortContinueItems(resume: [BaseItemDto], nextUp: [BaseItemDto]) -> [BaseItemDto] {
        // Both APIs return items sorted by activity:
        // - Resume: by DatePlayed descending (most recently played partial episode first)
        // - NextUp: by series activity (most recently finished series first)
        //
        // Strategy: Merge using a two-pointer approach, comparing dates.
        // For Resume items: use their lastPlayedDate
        // For NextUp items: use current time based on position (trust the API order)

        let now = Date()

        // Get effective dates for Resume items
        let resumeDates: [Date] = resume.map { item in
            parseDate(item.userData?.lastPlayedDate) ?? now
        }

        // For NextUp, assign dates based on position: first item = now, each subsequent = 1 second earlier
        // This trusts the NextUp API's sorting by series activity
        let nextUpDates: [Date] = nextUp.indices.map { index in
            now.addingTimeInterval(-Double(index))
        }

        // Merge the two sorted lists
        var merged: [BaseItemDto] = []
        var seenSeriesIds = Set<String>()
        var seenIds = Set<String>()

        var resumeIdx = 0
        var nextUpIdx = 0

        while resumeIdx < resume.count || nextUpIdx < nextUp.count {
            let useResume: Bool

            if resumeIdx >= resume.count {
                useResume = false
            } else if nextUpIdx >= nextUp.count {
                useResume = true
            } else {
                // Compare dates - take the more recent one
                useResume = resumeDates[resumeIdx] >= nextUpDates[nextUpIdx]
            }

            let item: BaseItemDto
            if useResume {
                item = resume[resumeIdx]
                resumeIdx += 1
            } else {
                item = nextUp[nextUpIdx]
                nextUpIdx += 1
            }

            // Skip duplicates
            guard !seenIds.contains(item.id) else { continue }

            // Skip if we already have an item from this series
            if let seriesId = item.seriesId {
                guard !seenSeriesIds.contains(seriesId) else { continue }
                seenSeriesIds.insert(seriesId)
            }

            seenIds.insert(item.id)
            merged.append(item)

            if merged.count >= 20 { break }
        }

        return merged
    }

    private func parseDate(_ dateString: String?) -> Date? {
        guard let dateString else { return nil }
        if let date = dateFormatter.date(from: dateString) {
            return date
        }
        return dateFormatterNoFraction.date(from: dateString)
    }

    private func isMediaLibrary(_ library: JellyfinLibrary) -> Bool {
        guard let collectionType = library.collectionType?.lowercased() else { return true }
        return ["movies", "tvshows", "music", "mixed", "homevideos"].contains(collectionType)
    }
}

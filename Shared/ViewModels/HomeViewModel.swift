import Foundation
import Combine
#if os(tvOS)
import TVServices
#endif

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var continueWatchingItems: [MediaItem] = []
    @Published var continueWatchingLibraryNames: [String: String] = [:]  // rawId -> libraryName
    @Published var recentlyAddedItems: [MediaItem] = []
    @Published var heroItems: [MediaItem] = []
    @Published var heroItemLibraryNames: [String: String] = [:]  // rawId -> libraryName
    @Published var libraryItems: [String: [MediaItem]] = [:]  // libraryRawId -> items
    @Published var libraries: [MediaLibrary] = []
    @Published var isLoading = false
    @Published var error: Error?

    private let serverManager = ServerManager.shared
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
        guard !serverManager.activeServers.isEmpty else { return }

        isLoading = true
        error = nil

        do {
            // Continue watching from active server(s)
            async let resumeTask = serverManager.getAllResumeItems()
            async let nextUpTask = serverManager.getAllNextUp()

            let resumeItems = await resumeTask
            let nextUpItems = await nextUpTask

            continueWatchingItems = mergeAndSortContinueItems(resume: resumeItems, nextUp: nextUpItems)

            // Libraries from active server(s)
            var allLibraries: [MediaLibrary] = []
            for server in serverManager.activeServers {
                let libs = (try? await server.getLibraries()) ?? []
                allLibraries.append(contentsOf: libs)
            }
            libraries = allLibraries.filter { isMediaLibrary($0) }

            // Recently added from active server(s)
            var allLatest: [MediaItem] = []
            for server in serverManager.activeServers {
                let items = (try? await server.getLatestMedia(libraryId: nil, limit: 30)) ?? []
                allLatest.append(contentsOf: items)
            }
            recentlyAddedItems = allLatest

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

        // Group items by server so we can resolve ancestors per-server
        var itemsByServer: [String: [MediaItem]] = [:]
        for item in continueWatchingItems {
            itemsByServer[item.serverId, default: []].append(item)
        }

        for (serverId, items) in itemsByServer {
            guard let server = serverManager.server(forId: serverId) else { continue }

            // For Jellyfin servers, use ancestor lookup for library names
            if server.serverType == .jellyfin {
                let seriesIds = Set(items.compactMap { item -> String? in
                    if item.type == .episode { return item.seriesId }
                    return item.rawId
                })

                for seriesId in seriesIds {
                    do {
                        let ancestors = try await JellyfinClient.shared.getItemAncestors(itemId: seriesId)
                        if let library = ancestors.first(where: { $0.type == .collectionFolder }) {
                            for item in items {
                                if item.seriesId == seriesId || item.rawId == seriesId {
                                    libraryNames[item.rawId] = library.name
                                }
                            }
                        }
                    } catch { }
                }
            }
            // For non-Jellyfin servers, library name resolution can be added later
        }

        continueWatchingLibraryNames = libraryNames
    }

    private func saveContinueWatchingForTopShelf() {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }

        let items: [[String: Any]] = continueWatchingItems.prefix(10).compactMap { item in
            guard let server = serverManager.server(forId: item.serverId) else { return nil }
            let serverURL = server.serverURL

            let seriesHasBackdrop = item.parentBackdropImageTags?.isEmpty == false
            let imageId: String
            let imageType: String

            switch item.type {
            case .episode:
                imageId = seriesHasBackdrop ? (item.seriesId ?? item.rawId) : item.rawId
                imageType = seriesHasBackdrop ? "Backdrop" : "Primary"
            case .video:
                imageId = item.rawId
                imageType = "Primary"
            default:
                imageId = item.rawId
                imageType = "Backdrop"
            }

            let imageURLString = "\(serverURL.absoluteString)/Items/\(imageId)/Images/\(imageType)?maxWidth=1920"
            guard let imageURL = URL(string: imageURLString) else { return nil }

            var subtitle = ""
            if item.type == .episode {
                let season = item.seasonNumber ?? 1
                let episode = item.episodeNumber ?? 1
                subtitle = "S\(season):E\(episode)"
                if let seriesName = item.seriesName {
                    subtitle = "\(seriesName) \u{2022} \(subtitle)"
                }
            }

            return [
                "id": item.rawId,
                "name": item.type == .episode ? (item.seriesName ?? item.title) : item.title,
                "subtitle": subtitle,
                "imageURL": imageURL.absoluteString,
                "type": item.type.rawValue,
                "progress": item.progressPercent
            ]
        }

        defaults.set(items, forKey: "continueWatchingItems")
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }

    private func loadHeroItems() async {
        var allHeroItems: [MediaItem] = []
        var libraryNames: [String: String] = [:]
        var itemsPerLibrary: [String: [MediaItem]] = [:]

        for server in serverManager.servers {
            let serverLibs = libraries.filter { $0.serverId == server.id }
            for library in serverLibs {
                do {
                    let items = try await server.getLatestMedia(libraryId: library.rawId, limit: 10)
                    itemsPerLibrary[library.rawId] = items
                    for item in items {
                        libraryNames[item.rawId] = library.name
                    }
                    allHeroItems.append(contentsOf: items.prefix(5))
                } catch { }
            }
        }

        heroItems = allHeroItems.shuffled()
        heroItemLibraryNames = libraryNames
        libraryItems = itemsPerLibrary
    }

    func refresh() async {
        await loadContent()
    }

    private func mergeAndSortContinueItems(resume: [MediaItem], nextUp: [MediaItem]) -> [MediaItem] {
        let now = Date()

        let resumeDates: [Date] = resume.map { item in
            parseDate(item.lastPlayedDate) ?? now
        }

        let nextUpDates: [Date] = nextUp.indices.map { index in
            now.addingTimeInterval(-Double(index))
        }

        var merged: [MediaItem] = []
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
                useResume = resumeDates[resumeIdx] >= nextUpDates[nextUpIdx]
            }

            let item: MediaItem
            if useResume {
                item = resume[resumeIdx]
                resumeIdx += 1
            } else {
                item = nextUp[nextUpIdx]
                nextUpIdx += 1
            }

            guard !seenIds.contains(item.rawId) else { continue }

            if let seriesId = item.seriesId {
                guard !seenSeriesIds.contains(seriesId) else { continue }
                seenSeriesIds.insert(seriesId)
            }

            seenIds.insert(item.rawId)
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

    private func isMediaLibrary(_ library: MediaLibrary) -> Bool {
        guard let collectionType = library.collectionType?.lowercased() else { return true }
        // Jellyfin: "movies", "tvshows", "music" — Plex: "movie", "show", "artist"
        return ["movies", "tvshows", "music", "mixed", "homevideos", "movie", "show", "artist"].contains(collectionType)
    }
}

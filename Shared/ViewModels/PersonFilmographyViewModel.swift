import Foundation
import Combine

enum PersonFilmographyState: Equatable {
    case idle
    case loading
    case loaded
    case unavailable
    case failed(String)
}

@MainActor
final class PersonFilmographyViewModel: ObservableObject {
    @Published private(set) var items: [ServerMediaResultGroup] = []
    @Published private(set) var state: PersonFilmographyState = .idle

    func load(
        person: PersonInfo,
        originatingServerID: String?,
        excludingItemID: String? = nil,
        excludingTitleKey: String? = nil,
        isOffline: Bool = false
    ) async {
        items = []
        state = isOffline ? .unavailable : .loading

        guard !isOffline else { return }

        do {
            let media = try await MultiServerPeopleService.search(
                person: person,
                originatingServerID: originatingServerID
            )
            guard !Task.isCancelled else { return }
            let visible = Self.visibleMedia(
                from: media,
                excludingItemID: excludingItemID,
                excludingServerID: originatingServerID,
                excludingTitleKey: excludingTitleKey
            )
            items = ServerMediaResultGrouping.groups(
                from: visible,
                preferredServerID: originatingServerID
            )
            state = .loaded
        } catch is CancellationError {
            // The view disappeared or a newer load replaced this one.
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Filters server-scoped results before grouping them for presentation.
    /// The group operation removes duplicate copies within each server; this
    /// filter removes the source title from every server when its presentation
    /// identity is known.
    static func visibleMedia(
        from media: [ServerMediaResult],
        excludingItemID: String?,
        excludingServerID: String?,
        excludingTitleKey: String?
    ) -> [ServerMediaResult] {
        var seenIDs = Set<String>()
        return media.filter { result in
            guard result.item.type == .movie || result.item.type == .series else {
                return false
            }
            if let excludingTitleKey,
               ServerMediaResultGrouping.titleKey(for: result.item) == excludingTitleKey {
                return false
            }
            if let excludingItemID,
               result.item.id == excludingItemID,
               result.serverID == excludingServerID {
                return false
            }
            return seenIDs.insert(result.id).inserted
        }
    }

    /// Kept as a focused model helper for callers that already have one
    /// server's raw Jellyfin response (and for the existing unit coverage).
    static func visibleMedia(from media: [BaseItemDto], excludingItemID: String?) -> [BaseItemDto] {
        var seenIDs = Set<String>()
        return media.filter { item in
            guard item.id != excludingItemID,
                  item.type == .movie || item.type == .series else {
                return false
            }
            return seenIDs.insert(item.id).inserted
        }
    }
}

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
    @Published private(set) var items: [BaseItemDto] = []
    @Published private(set) var state: PersonFilmographyState = .idle

    func load(personID: String, excludingItemID: String? = nil, isOffline: Bool = false) async {
        items = []
        state = isOffline ? .unavailable : .loading

        guard !isOffline else { return }

        do {
            let media = try await JellyfinClient.shared.getPersonMedia(personId: personID)
            guard !Task.isCancelled else { return }
            items = Self.visibleMedia(from: media, excludingItemID: excludingItemID)
            state = .loaded
        } catch is CancellationError {
            // The view disappeared or a newer load replaced this one.
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }

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

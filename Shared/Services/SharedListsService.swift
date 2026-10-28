import Foundation

/// A list as the Lists page shows it.
struct SharedList: Identifiable, Hashable {
    let id: String
    let name: String
    /// Nil for a list made outside Sashimi (no self-share): "Shared list".
    let ownerId: String?
    let isPublic: Bool
    let imageTag: String?

    func isOwned(by userId: String?) -> Bool {
        guard let userId, let ownerId else { return false }
        return ownerId == userId
    }
}

/// What a list shows the current user.
struct ListContents: Equatable {
    /// The entries the user may see, in list order (parental limits applied
    /// by the server). Owner tools address these by `playlistItemId`.
    let entries: [BaseItemDto]
    /// One card per displayed title, after the series and repeat rules.
    let items: [BaseItemDto]

    /// What "seen" and "N new" compare. A series card's id is the series id.
    var displayIds: [String] { items.map(\.id) }

    static let empty = ListContents(entries: [], items: [])
}

enum AddToListResult: Equatable {
    case added
    case alreadyOnList
}

enum SharedListsError: LocalizedError, Equatable {
    case noEpisodes
    case unsupportedType

    var errorDescription: String? {
        switch self {
        case .noEpisodes: return "This show has no episodes to add yet."
        case .unsupportedType: return "Only movies, shows and episodes can go on a list."
        }
    }
}

/// The API side of shared lists (plan Milestone 2): Jellyfin playlists, the
/// self-share that records the creator, and each user's subscriptions in
/// DisplayPreferences. Every count comes from the filtered `/Items` listing,
/// never from `PlaylistDto.ItemIds`.
struct SharedListsService {
    let client: JellyfinClient

    init(client: JellyfinClient = .shared) {
        self.client = client
    }

    static func isGone(_ error: Error) -> Bool {
        if case JellyfinError.httpError(statusCode: 404) = error { return true }
        return false
    }

    // MARK: Lists

    /// Your lists and everyone's public ones. A list that vanishes between
    /// the listing and its sharing lookup is left out.
    func lists() async throws -> [SharedList] {
        let playlists = try await client.getPlaylists()
        return try await withThrowingTaskGroup(of: (Int, SharedList?).self) { group in
            for (index, playlist) in playlists.enumerated() {
                group.addTask {
                    do {
                        return (index, try await list(from: playlist))
                    } catch where Self.isGone(error) {
                        return (index, nil)
                    }
                }
            }
            var found: [(Int, SharedList)] = []
            for try await (index, list) in group {
                if let list { found.append((index, list)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    func list(from playlist: BaseItemDto) async throws -> SharedList {
        let sharing = try await client.getPlaylistSharing(playlistId: playlist.id)
        return SharedList(
            id: playlist.id,
            name: playlist.name,
            ownerId: SharedLists.owner(shares: sharing.shares),
            isPublic: sharing.openAccess,
            imageTag: playlist.imageTags?["Primary"]
        )
    }

    /// The lists with these ids that this user can still see. A missing one
    /// is gone (deleted, or made private by its owner).
    func lists(ids: [String]) async throws -> (found: [SharedList], missing: [String]) {
        guard !ids.isEmpty else { return ([], []) }
        let playlists = try await client.getItemsForCards(itemIds: ids)
        var found: [SharedList] = []
        var missing: [String] = []
        for id in ids {
            guard let playlist = playlists.first(where: { $0.id == id }) else {
                missing.append(id)
                continue
            }
            do {
                found.append(try await list(from: playlist))
            } catch where Self.isGone(error) {
                missing.append(id)
            }
        }
        return (found, missing)
    }

    /// The titles the list shows this user: S1:E1 entries become their series
    /// card and repeats show once.
    func contents(of listId: String) async throws -> ListContents {
        let entries = try await client.getPlaylistEntries(playlistId: listId)
        let display = SharedLists.displayEntries(entries.map(ListEntry.init(item:)))
        let seriesIds = display.filter(\.isSeries).map(\.id)
        let series = seriesIds.isEmpty ? [] : ((try? await client.getItemsForCards(itemIds: seriesIds)) ?? [])
        let items: [BaseItemDto] = display.compactMap { shown in
            if shown.isSeries {
                // The series may be hidden from this user while the pilot is
                // not; the pilot stands in rather than dropping the title.
                return series.first { $0.id == shown.id }
                    ?? entries.first { $0.seriesId == shown.id }
            }
            return entries.first { $0.id == shown.id }
        }
        return ListContents(entries: entries, items: items)
    }

    // MARK: Editing

    /// What goes on a list for `item`: itself, or a show's first episode
    /// (adding the series id would add every episode).
    func listEntry(for item: BaseItemDto) async throws -> BaseItemDto {
        switch item.type {
        case .movie, .episode, .video:
            return item
        case .series:
            let episodes = try await client.getEpisodes(seriesId: item.id)
            guard let anchor = SharedLists.seriesAnchor(episodes) else { throw SharedListsError.noEpisodes }
            return anchor
        default:
            throw SharedListsError.unsupportedType
        }
    }

    /// Creates a list owned by the current user. The self-share is what
    /// records the creator; without it the list would show as nobody's, so a
    /// failed share deletes the list again.
    func create(name: String, isPublic: Bool, adding item: BaseItemDto?) async throws -> String {
        guard let userId = await client.currentUserId else { throw JellyfinError.notConfigured }
        var entry: BaseItemDto?
        if let item { entry = try await listEntry(for: item) }
        let listId = try await client.createPlaylist(name: name, itemIds: entry.map { [$0.id] } ?? [], isPublic: isPublic)
        do {
            try await client.sharePlaylist(playlistId: listId, userId: userId, canEdit: true)
        } catch {
            try? await client.deleteItem(itemId: listId)
            throw error
        }
        return listId
    }

    /// Adds `item` unless the list already shows it.
    func add(_ item: BaseItemDto, to listId: String) async throws -> AddToListResult {
        let entry = try await listEntry(for: item)
        let current = try await client.getPlaylistEntries(playlistId: listId)
        if SharedLists.contains(current.map(ListEntry.init(item:)), candidate: ListEntry(item: entry)) {
            return .alreadyOnList
        }
        try await client.addToPlaylist(playlistId: listId, itemIds: [entry.id])
        return .added
    }

    /// Whether the list already shows `item` (for the picker's "Already on
    /// this list"). A series is checked by its id, which is what its S1:E1
    /// entry displays as.
    func shows(_ item: BaseItemDto, in contents: ListContents) -> Bool {
        let candidate = ListEntry(item: item)
        if item.type == .series { return contents.displayIds.contains(item.id) }
        return SharedLists.contains(contents.entries.map(ListEntry.init(item:)), candidate: candidate)
    }

    /// Removes every entry the displayed title stands for, so a title added
    /// twice does not reappear.
    func remove(_ shown: BaseItemDto, from listId: String, contents: ListContents) async throws {
        let entryIds = contents.entries
            .filter { SharedLists.displayEntry(ListEntry(item: $0)).id == shown.id }
            .map { $0.playlistItemId ?? $0.id }
        guard !entryIds.isEmpty else { return }
        try await client.removeFromPlaylist(playlistId: listId, entryIds: entryIds)
    }

    /// Moves a displayed title to `index` among the list's entries.
    func move(_ shown: BaseItemDto, to index: Int, in listId: String, contents: ListContents) async throws {
        guard let entry = contents.entries.first(where: { SharedLists.displayEntry(ListEntry(item: $0)).id == shown.id }),
              index >= 0, index < contents.items.count else { return }
        // Display index → entry index: the entry that the title now at
        // `index` came from.
        let target = contents.items[index]
        let entryIndex = contents.entries.firstIndex { SharedLists.displayEntry(ListEntry(item: $0)).id == target.id } ?? index
        try await client.movePlaylistEntry(playlistId: listId, entryId: entry.playlistItemId ?? entry.id, to: entryIndex)
    }

    func rename(_ listId: String, to name: String) async throws {
        try await client.updatePlaylist(playlistId: listId, name: name, isPublic: nil)
    }

    func setPublic(_ listId: String, _ isPublic: Bool) async throws {
        try await client.updatePlaylist(playlistId: listId, name: nil, isPublic: isPublic)
    }

    func delete(_ listId: String) async throws {
        try await client.deleteItem(itemId: listId)
    }

    // MARK: People

    func userNames() async throws -> [String: String] {
        Dictionary(try await client.getUsers().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Subscriptions

    func loadSubscriptions() async throws -> [ListSubscription] {
        let data = try await client.getDisplayPreferences(id: SharedLists.preferencesId, client: SharedLists.preferencesClient)
        return SharedLists.subscriptions(inDisplayPreferences: data)
    }

    /// Read, change, write back. The last write wins, which the design
    /// accepts; other keys in the same entry are kept.
    @discardableResult
    func updateSubscriptions(_ change: ([ListSubscription]) -> [ListSubscription]) async throws -> [ListSubscription] {
        let stored = try await client.getDisplayPreferences(id: SharedLists.preferencesId, client: SharedLists.preferencesClient)
        let updated = change(SharedLists.subscriptions(inDisplayPreferences: stored))
        let body = SharedLists.displayPreferencesBody(stored: stored, subscriptions: updated)
        try await client.saveDisplayPreferences(id: SharedLists.preferencesId, client: SharedLists.preferencesClient, body: body)
        return updated
    }
}

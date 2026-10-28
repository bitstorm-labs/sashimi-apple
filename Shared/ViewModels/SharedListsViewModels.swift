import Foundation

/// A list's card on the Lists page.
struct ListCard: Identifiable, Hashable {
    let list: SharedList
    let ownerName: String?
    /// What this user sees on it (parental limits applied).
    let count: Int
    /// The cover's posters (`SharedLists.coverPosterIds`): four for a 2x2
    /// collage, one shown full-bleed, or none.
    let coverIds: [String]

    var id: String { list.id }

    /// "Public · 12 titles", or "Marge · 18 titles" for someone else's list.
    func subtitle(isOwn: Bool) -> String {
        let who = isOwn ? (list.isPublic ? "Public" : "Private") : (ownerName ?? "Shared list")
        return "\(who) · \(ListText.titles(count))"
    }
}

enum ListText {
    static func titles(_ count: Int) -> String {
        count == 1 ? "1 title" : "\(count) titles"
    }

    static func creator(ownerName: String?, isOwn: Bool) -> String {
        if isOwn { return "Your list" }
        guard let ownerName else { return "Shared list" }
        return "A list by \(ownerName)"
    }

    static let publicFootnote = "Everyone on the server can find and subscribe to it."
}

/// The Lists page: your lists and everyone's public ones.
@MainActor
final class ListsPageViewModel: ObservableObject {
    @Published private(set) var mine: [ListCard] = []
    @Published private(set) var others: [ListCard] = []
    @Published private(set) var isLoading = true
    @Published private(set) var failed = false

    private let service: SharedListsService
    private let store: SharedListsStore

    init(service: SharedListsService = SharedListsService(), store: SharedListsStore = .shared) {
        self.service = service
        self.store = store
    }

    func load() async {
        failed = false
        do {
            let userId = await service.client.currentUserId
            async let names: Void = store.loadUserNames()
            let lists = try await service.lists()
            _ = await names
            let cards = await withTaskGroup(of: (Int, ListCard).self) { group in
                for (index, list) in lists.enumerated() {
                    group.addTask { [service, store] in
                        let contents = (try? await service.contents(of: list.id)) ?? .empty
                        let owner = await store.ownerName(of: list)
                        return (index, ListCard(list: list, ownerName: owner, count: contents.items.count, coverIds: contents.coverIds))
                    }
                }
                var cards: [(Int, ListCard)] = []
                for await card in group { cards.append(card) }
                return cards.sorted { $0.0 < $1.0 }.map(\.1)
            }
            mine = cards.filter { $0.list.isOwned(by: userId) }
            // Another user's list is only here when it is public; a private
            // list shared some other way is still someone else's.
            others = cards.filter { !$0.list.isOwned(by: userId) }
        } catch is CancellationError {
            return
        } catch {
            failed = mine.isEmpty && others.isEmpty
        }
        isLoading = false
    }

    /// Creates an empty list and returns it, or nil on failure.
    func create(name: String, isPublic: Bool) async -> SharedList? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let id = try await service.create(name: trimmed, isPublic: isPublic, adding: nil)
            let userId = await service.client.currentUserId
            // Shown as the server has it, not as asked.
            let serverPublic = (try? await service.isPublic(id)) ?? isPublic
            let list = SharedList(id: id, name: trimmed, ownerId: userId, isPublic: serverPublic, imageTag: nil)
            mine.append(ListCard(list: list, ownerName: nil, count: 0, coverIds: []))
            return list
        } catch {
            return nil
        }
    }
}

/// One list's page. Opening a subscribed list marks what it shows as seen;
/// the titles that were new stay marked for this visit.
@MainActor
final class ListDetailViewModel: ObservableObject {
    @Published private(set) var list: SharedList
    @Published private(set) var contents: ListContents = .empty
    @Published private(set) var isLoading = true
    @Published private(set) var failed = false
    /// The list was deleted or made private while open.
    @Published private(set) var isGone = false
    @Published private(set) var newIds: Set<String> = []
    @Published private(set) var userId: String?
    /// A Public/Private switch is waiting for the server to confirm it.
    @Published private(set) var isChangingVisibility = false

    private let service: SharedListsService
    let store: SharedListsStore
    private let settle: Duration

    init(list: SharedList, service: SharedListsService = SharedListsService(), store: SharedListsStore = .shared,
         settle: Duration = .seconds(2)) {
        self.list = list
        self.service = service
        self.store = store
        self.settle = settle
    }

    var isOwner: Bool { list.isOwned(by: userId) }
    var isSubscribed: Bool { store.isSubscribed(list.id) }
    var ownerName: String? { store.ownerName(of: list) }
    var creatorLine: String { ListText.creator(ownerName: ownerName, isOwn: isOwner) }

    var summary: String {
        var parts = [ListText.titles(contents.items.count)]
        if isSubscribed, !newIds.isEmpty { parts.append("\(newIds.count) new since you last looked") }
        if isOwner {
            parts.append(list.isPublic ? "Public: everyone on the server can see and subscribe" : "Private: only you can see it")
        }
        return parts.joined(separator: " · ")
    }

    func load() async {
        userId = await service.client.currentUserId
        if store.userNames.isEmpty { await store.loadUserNames() }
        // The owner (plugin, else self-share, else self-check) and the
        // server's Public/Private, whatever the card that opened it said.
        if let fresh = try? await service.refreshed(list) { list = fresh }
        do {
            let loaded = try await service.contents(of: list.id)
            contents = loaded
            failed = false
            if let seen = store.subscriptions.first(where: { $0.id == list.id })?.seen {
                newIds = newIds.union(loaded.displayIds.filter { !seen.contains($0) })
                await store.markSeen(list.id, current: loaded)
            }
        } catch where SharedListsService.isGone(error) {
            isGone = true
            if isSubscribed { await store.unsubscribe(from: list.id) }
        } catch is CancellationError {
            return
        } catch {
            failed = contents.items.isEmpty
        }
        isLoading = false
    }

    /// Returns the message to show.
    func toggleSubscription() async -> String {
        if isSubscribed {
            return await store.unsubscribe(from: list.id) ? "Unsubscribed" : "Couldn't unsubscribe"
        }
        let saved = await store.subscribe(to: list, current: contents)
        return saved ? "Subscribed: it's on your Home screen" : "Couldn't subscribe"
    }

    func rename(to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != list.name else { return false }
        do {
            try await service.rename(list.id, to: trimmed)
            list = list.with(name: trimmed)
            return true
        } catch {
            return false
        }
    }

    /// Switches Public/Private. What shows afterwards is what the server
    /// says (OpenAccess), never the value asked for: Jellyfin 12.4 can revert
    /// it a second later, which the service checks for and repairs once.
    func togglePublic() async -> Bool {
        let wanted = !list.isPublic
        isChangingVisibility = true
        defer { isChangingVisibility = false }
        do {
            let now = try await service.setPublicVerified(list.id, wanted, settle: settle)
            list = list.with(isPublic: now)
            return now == wanted
        } catch {
            if let now = try? await service.isPublic(list.id) { list = list.with(isPublic: now) }
            return false
        }
    }

    func remove(_ item: BaseItemDto) async -> Bool {
        do {
            try await service.remove(item, from: list.id, contents: contents)
            await reload()
            return true
        } catch {
            return false
        }
    }

    /// Moves a title by `offset` places (negative is earlier), clamped.
    func move(_ item: BaseItemDto, by offset: Int) async -> Bool {
        guard let from = contents.items.firstIndex(where: { $0.id == item.id }) else { return false }
        let target = min(max(from + offset, 0), contents.items.count - 1)
        guard target != from else { return false }
        do {
            try await service.move(item, to: target, in: list.id, contents: contents)
            await reload()
            return true
        } catch {
            return false
        }
    }

    func canMove(_ item: BaseItemDto, by offset: Int) -> Bool {
        guard let from = contents.items.firstIndex(where: { $0.id == item.id }) else { return false }
        let target = from + offset
        return target >= 0 && target < contents.items.count
    }

    func delete() async -> Bool {
        do {
            try await service.delete(list.id)
            if isSubscribed { await store.unsubscribe(from: list.id) }
            return true
        } catch {
            return false
        }
    }

    private func reload() async {
        if let loaded = try? await service.contents(of: list.id) {
            contents = loaded
            if isSubscribed { await store.markSeen(list.id, current: loaded) }
        }
    }
}

/// The Add to List picker for one title.
@MainActor
final class AddToListViewModel: ObservableObject {
    struct Choice: Identifiable, Equatable {
        let list: SharedList
        let count: Int
        let alreadyOn: Bool

        var id: String { list.id }
        var detail: String {
            alreadyOn ? "Already on this list" : "\(list.isPublic ? "Public" : "Private") · \(count)"
        }
    }

    let item: BaseItemDto
    @Published private(set) var choices: [Choice] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isWorking = false

    private let service: SharedListsService

    init(item: BaseItemDto, service: SharedListsService = SharedListsService()) {
        self.item = item
        self.service = service
    }

    var title: String { "Add “\(item.name)” to…" }

    /// Only your own lists: nobody can add to someone else's.
    func load() async {
        let userId = await service.client.currentUserId
        let lists = ((try? await service.lists()) ?? []).filter { $0.isOwned(by: userId) }
        var loaded: [Choice] = []
        for list in lists {
            let contents = (try? await service.contents(of: list.id)) ?? .empty
            loaded.append(Choice(list: list, count: contents.items.count, alreadyOn: service.shows(item, in: contents)))
        }
        choices = loaded
        isLoading = false
    }

    /// Returns the message to show.
    func add(to list: SharedList) async -> String {
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await service.add(item, to: list.id) {
            case .added: return "Added to \(list.name)"
            case .alreadyOnList: return "Already on \(list.name)"
            }
        } catch {
            return (error as? SharedListsError)?.errorDescription ?? "Couldn't add to \(list.name)"
        }
    }

    /// Creates a list with this title on it. Returns the message to show.
    func create(name: String, isPublic: Bool) async -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Give the list a name" }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await service.create(name: trimmed, isPublic: isPublic, adding: item)
            return "Added to \(trimmed)"
        } catch {
            return (error as? SharedListsError)?.errorDescription ?? "Couldn't create the list"
        }
    }
}

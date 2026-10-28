import Foundation
import os

private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "SharedLists")

/// A subscribed list as its home row shows it.
struct SubscribedListRow: Identifiable, Equatable {
    let list: SharedList
    let ownerName: String?
    let contents: ListContents
    let seen: [String]

    var id: String { list.id }
    var title: String { SharedLists.rowTitle(listName: list.name, ownerName: ownerName) }
    var newCount: Int { SharedLists.newCount(displayIds: contents.displayIds, seen: seen) }

    func isNew(_ itemId: String) -> Bool { !seen.contains(itemId) }
}

/// The current user's subscriptions and their home rows, shared by every
/// screen. Home asks it to refresh and never waits on it: each row appears
/// when its list has loaded.
@MainActor
final class SharedListsStore: ObservableObject {
    static let shared = SharedListsStore()

    /// In the order the user subscribed.
    @Published private(set) var subscriptions: [ListSubscription] = []
    /// Keyed by list id. A list that failed to load or is gone has no row.
    @Published private(set) var rows: [String: SubscribedListRow] = [:]
    /// Lists the user subscribed to, with their names, for Home's row
    /// settings. Set on every refresh.
    @Published private(set) var subscribedLists: [SharedList] = []
    @Published private(set) var userNames: [String: String] = [:]

    private let service: SharedListsService
    private var loadedUserId: String?

    init(service: SharedListsService = SharedListsService()) {
        self.service = service
    }

    var currentUserId: String? { loadedUserId }

    func isSubscribed(_ listId: String) -> Bool {
        subscriptions.contains { $0.id == listId }
    }

    func ownerName(of list: SharedList) -> String? {
        list.ownerId.flatMap { userNames[$0] }
    }

    /// Reloads the subscriptions and every subscribed list. Lists the server
    /// answers 404 for (deleted, or made private) lose their row and are
    /// pruned from the saved subscriptions.
    func refresh() async {
        let userId = await service.client.currentUserId
        if userId != loadedUserId {
            // Another user or server: nothing of the last one may show.
            subscriptions = []
            rows = [:]
            subscribedLists = []
            userNames = [:]
            loadedUserId = userId
        }
        do {
            async let names = service.userNames()
            let subs = try await service.loadSubscriptions()
            subscriptions = subs
            let (found, missing) = try await service.lists(ids: subs.map(\.id))
            userNames = (try? await names) ?? userNames
            subscribedLists = found
            var loaded: [String: SubscribedListRow] = [:]
            var gone = missing
            for list in found {
                do {
                    let contents = try await service.contents(of: list.id)
                    let seen = subs.first { $0.id == list.id }?.seen ?? []
                    loaded[list.id] = SubscribedListRow(list: list, ownerName: ownerName(of: list), contents: contents, seen: seen)
                } catch where SharedListsService.isGone(error) {
                    gone.append(list.id)
                } catch {
                    if let old = rows[list.id] { loaded[list.id] = old }
                }
            }
            rows = loaded
            if !gone.isEmpty {
                subscribedLists.removeAll { gone.contains($0.id) }
                _ = await save { SharedLists.prune($0, missing: gone) }
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("Lists refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Subscribes with everything currently on the list already seen.
    @discardableResult
    func subscribe(to list: SharedList, current: ListContents) async -> Bool {
        guard await save({ SharedLists.subscribe($0, id: list.id, current: current.displayIds) }) else { return false }
        if !subscribedLists.contains(where: { $0.id == list.id }) { subscribedLists.append(list) }
        rows[list.id] = SubscribedListRow(list: list, ownerName: ownerName(of: list), contents: current, seen: current.displayIds)
        return true
    }

    @discardableResult
    func unsubscribe(from listId: String) async -> Bool {
        guard await save({ SharedLists.unsubscribe($0, id: listId) }) else { return false }
        subscribedLists.removeAll { $0.id == listId }
        rows[listId] = nil
        return true
    }

    /// Opening a subscribed list replaces what was seen with what is shown.
    func markSeen(_ listId: String, current: ListContents) async {
        guard let sub = subscriptions.first(where: { $0.id == listId }),
              sub.seen != current.displayIds else { return }
        _ = await save { SharedLists.markSeen($0, id: listId, current: current.displayIds) }
        if let row = rows[listId] {
            rows[listId] = SubscribedListRow(list: row.list, ownerName: row.ownerName, contents: current, seen: current.displayIds)
        }
    }

    /// Loads the creator names for the Lists page.
    func loadUserNames() async {
        if let names = try? await service.userNames() { userNames = names }
    }

    private func save(_ change: @escaping ([ListSubscription]) -> [ListSubscription]) async -> Bool {
        do {
            subscriptions = try await service.updateSubscriptions(change)
            return true
        } catch {
            logger.error("Saving list subscriptions failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

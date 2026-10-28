import Foundation

/// A playlist share as Jellyfin reports it (`GET /Playlists/{id}` → `Shares`).
struct PlaylistShare: Codable, Equatable {
    let userId: String
    let canEdit: Bool

    enum CodingKeys: String, CodingKey {
        case userId = "UserId"
        case canEdit = "CanEdit"
    }

    init(userId: String, canEdit: Bool) {
        self.userId = userId
        self.canEdit = canEdit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        canEdit = try container.decodeIfPresent(Bool.self, forKey: .canEdit) ?? false
    }
}

/// One entry of a list, reduced to what the display rules need.
struct ListEntry: Equatable {
    let itemId: String
    let type: ItemType?
    let seriesId: String?
    let season: Int?
    let episode: Int?

    init(itemId: String, type: ItemType?, seriesId: String?, season: Int?, episode: Int?) {
        self.itemId = itemId
        self.type = type
        self.seriesId = seriesId
        self.season = season
        self.episode = episode
    }

    init(item: BaseItemDto) {
        self.init(itemId: item.id, type: item.type, seriesId: item.seriesId,
                  season: item.parentIndexNumber, episode: item.indexNumber)
    }
}

/// What a list shows: an item, or the series an S1:E1 entry stands for.
struct DisplayEntry: Equatable {
    let id: String
    let isSeries: Bool
}

/// One subscribed list and the titles the subscriber had seen on it.
struct ListSubscription: Codable, Equatable {
    let id: String
    var seen: [String]
}

/// The rules every Sashimi client shares for lists (shared lists design,
/// 2026-10-27). Pure, so the same test vectors run on Apple, Android and Roku.
enum SharedLists {
    /// Literal values every platform uses, so a subscription made on one
    /// shows up on the others.
    static let preferencesId = "sashimi-lists"
    static let preferencesClient = "sashimi"
    static let subscriptionsKey = "subscriptions"

    /// Jellyfin does not report a playlist's owner. Sashimi shares each list it
    /// creates with its creator, so the first editable share is the owner.
    static func owner(shares: [PlaylistShare]) -> String? {
        shares.first(where: \.canEdit)?.userId
    }

    /// A show goes on a list as its S1:E1 (adding the series would add every
    /// episode), so S1:E1 is shown as the series. Repeats show once.
    static func displayEntries(_ entries: [ListEntry]) -> [DisplayEntry] {
        var shown: [DisplayEntry] = []
        var ids: Set<String> = []
        for entry in entries {
            let display = displayEntry(entry)
            if ids.insert(display.id).inserted { shown.append(display) }
        }
        return shown
    }

    static func displayEntry(_ entry: ListEntry) -> DisplayEntry {
        if entry.type == .episode, entry.season == 1, entry.episode == 1, let seriesId = entry.seriesId {
            return DisplayEntry(id: seriesId, isSeries: true)
        }
        return DisplayEntry(id: entry.itemId, isSeries: false)
    }

    /// Whether `candidate` would show as something the list already shows.
    static func contains(_ entries: [ListEntry], candidate: ListEntry) -> Bool {
        let target = displayEntry(candidate).id
        return entries.contains { $0.itemId == candidate.itemId || displayEntry($0).id == target }
    }

    /// The episode a show goes on a list as: the lowest season ≥ 1, then the
    /// lowest episode. Specials and unnumbered episodes never anchor it.
    static func seriesAnchor(_ episodes: [BaseItemDto]) -> BaseItemDto? {
        episodes
            .filter { ($0.parentIndexNumber ?? 0) >= 1 && $0.indexNumber != nil }
            .min { lhs, rhs in
                let left = (lhs.parentIndexNumber ?? 0, lhs.indexNumber ?? 0)
                let right = (rhs.parentIndexNumber ?? 0, rhs.indexNumber ?? 0)
                return left < right
            }
    }

    /// Anything unreadable is no subscriptions; entries without an id are
    /// dropped and a repeated id keeps its first entry.
    static func decodeSubscriptions(_ raw: String?) -> [ListSubscription] {
        struct Loose: Decodable {
            let id: String?
            let seen: [String]?
        }
        guard let data = raw?.data(using: .utf8),
              let loose = try? JSONDecoder().decode([Loose].self, from: data) else { return [] }
        var subs: [ListSubscription] = []
        for item in loose {
            guard let id = item.id, !subs.contains(where: { $0.id == id }) else { continue }
            subs.append(ListSubscription(id: id, seen: item.seen ?? []))
        }
        return subs
    }

    static func encodeSubscriptions(_ subs: [ListSubscription]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(subs) else { return "[]" }
        return String(bytes: data, encoding: .utf8) ?? "[]"
    }

    static func newCount(displayIds: [String], seen: [String]) -> Int {
        let seenSet = Set(seen)
        return displayIds.filter { !seenSet.contains($0) }.count
    }

    /// A new subscription has seen everything on the list, so it starts at 0 new.
    static func subscribe(_ subs: [ListSubscription], id: String, current: [String]) -> [ListSubscription] {
        guard !subs.contains(where: { $0.id == id }) else { return subs }
        return subs + [ListSubscription(id: id, seen: current)]
    }

    static func unsubscribe(_ subs: [ListSubscription], id: String) -> [ListSubscription] {
        subs.filter { $0.id != id }
    }

    static func markSeen(_ subs: [ListSubscription], id: String, current: [String]) -> [ListSubscription] {
        subs.map { $0.id == id ? ListSubscription(id: id, seen: current) : $0 }
    }

    /// Drops lists the server no longer shows this user (deleted or private).
    static func prune(_ subs: [ListSubscription], missing: [String]) -> [ListSubscription] {
        let gone = Set(missing)
        return subs.filter { !gone.contains($0.id) }
    }

    /// A new subscription's row goes after Continue Watching, else after the
    /// hero, else first.
    static func insertionIndex(rowKeys: [String], continueWatchingKey: String, heroKey: String) -> Int {
        if let index = rowKeys.firstIndex(of: continueWatchingKey) { return index + 1 }
        if let index = rowKeys.firstIndex(of: heroKey) { return index + 1 }
        return 0
    }

    /// A subscribed list's home row title.
    static func rowTitle(listName: String, ownerName: String?) -> String {
        guard let ownerName, !ownerName.isEmpty else { return listName }
        return "From \(ownerName): \(listName)"
    }

    /// The DisplayPreferences body to post back: what the server stored, with
    /// only `CustomPrefs.subscriptions` replaced. Every other key survives.
    static func displayPreferencesBody(stored: Data?, subscriptions: [ListSubscription]) -> Data {
        var object = stored.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if object["Client"] == nil { object["Client"] = preferencesClient }
        if object["Id"] == nil { object["Id"] = preferencesId }
        var prefs = object["CustomPrefs"] as? [String: Any] ?? [:]
        prefs[subscriptionsKey] = encodeSubscriptions(subscriptions)
        object["CustomPrefs"] = prefs
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    /// The stored subscriptions inside a DisplayPreferences body.
    static func subscriptions(inDisplayPreferences data: Data?) -> [ListSubscription] {
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let prefs = object?["CustomPrefs"] as? [String: Any]
        return decodeSubscriptions(prefs?[subscriptionsKey] as? String)
    }
}

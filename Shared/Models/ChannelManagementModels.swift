import Foundation

// The Channels plugin's management API (plugin `/VirtualChannels/Manage`).
// Admin-only on the server; the app hides every entry point for anyone else.
// Ids are Jellyfin-style undashed lowercase GUIDs, like the rest of the API.

/// A channel as the management endpoints describe it — enough to list it,
/// rename it, and show what was added to it by hand.
struct ManagedChannel: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let number: Int?
    /// The channel's configured logo key, if it has one.
    let logo: String?
    /// More than one daypart, or any seasonal window. Such a channel is added
    /// to per daypart, so the Add to Channel menu asks which one.
    let isScheduled: Bool
    let dayparts: [ManagedDaypart]

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case number = "Number"
        case logo = "Logo"
        case isScheduled = "IsScheduled"
        case dayparts = "Dayparts"
    }

    init(id: String, name: String, number: Int?, logo: String?, isScheduled: Bool, dayparts: [ManagedDaypart]) {
        self.id = id
        self.name = name
        self.number = number
        self.logo = logo
        self.isScheduled = isScheduled
        self.dayparts = dayparts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        number = try container.decodeIfPresent(Int.self, forKey: .number)
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        isScheduled = try container.decodeIfPresent(Bool.self, forKey: .isScheduled) ?? false
        dayparts = try container.decodeIfPresent([ManagedDaypart].self, forKey: .dayparts) ?? []
    }

    /// Every title added by hand, across dayparts.
    var addedItemCount: Int { dayparts.reduce(0) { $0 + $1.addedItems.count } }

    /// Something other than hand-added titles feeds the channel (a genre, a
    /// library, another collection), so emptying the added list keeps it on air.
    var hasRule: Bool { dayparts.contains { $0.ruleSummary?.isEmpty == false } }

    /// Removing this added title would leave the channel with nothing to air:
    /// nothing else was added and no rule feeds it. The UI asks first.
    ///
    /// Mirrors what the server removes: a series from the one daypart named
    /// (every daypart when none is), a film from the whole channel — the
    /// managed collection belongs to the channel, not to a daypart.
    func removingTakesOffAir(itemId: String, daypartIndex: Int? = nil) -> Bool {
        guard !hasRule else { return false }
        let remaining = dayparts.reduce(0) { total, daypart in
            total + daypart.addedItems.filter { added in
                guard added.id == itemId else { return true }
                let isSeries = added.type == "Series"
                return isSeries && daypartIndex != nil && daypart.index != daypartIndex
            }.count
        }
        return remaining == 0
    }
}

struct ManagedDaypart: Codable, Identifiable, Equatable {
    let index: Int
    let name: String
    let startMinutes: Int
    let endMinutes: Int
    let isSeasonal: Bool
    /// Titles the client may remove: series in the daypart's Series blocks and
    /// members of the channel's own managed collection.
    let addedItems: [ManagedItem]
    /// Human text for what else feeds the daypart ("Science Fiction",
    /// "Library: Movies"); nil when only added titles do.
    let ruleSummary: String?

    var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case name = "Name"
        case startMinutes = "StartMinutes"
        case endMinutes = "EndMinutes"
        case isSeasonal = "IsSeasonal"
        case addedItems = "AddedItems"
        case ruleSummary = "RuleSummary"
    }

    init(
        index: Int,
        name: String,
        startMinutes: Int = 0,
        endMinutes: Int = 1440,
        isSeasonal: Bool = false,
        addedItems: [ManagedItem] = [],
        ruleSummary: String? = nil
    ) {
        self.index = index
        self.name = name
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.isSeasonal = isSeasonal
        self.addedItems = addedItems
        self.ruleSummary = ruleSummary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        name = try container.decode(String.self, forKey: .name)
        startMinutes = try container.decodeIfPresent(Int.self, forKey: .startMinutes) ?? 0
        endMinutes = try container.decodeIfPresent(Int.self, forKey: .endMinutes) ?? 1440
        isSeasonal = try container.decodeIfPresent(Bool.self, forKey: .isSeasonal) ?? false
        addedItems = try container.decodeIfPresent([ManagedItem].self, forKey: .addedItems) ?? []
        ruleSummary = try container.decodeIfPresent(String.self, forKey: .ruleSummary)
    }

    /// "18:00–23:00", or nil for an all-day daypart, where a time range says nothing.
    var timeRangeLabel: String? {
        guard !(startMinutes == 0 && (endMinutes == 1440 || endMinutes == 0)) else { return nil }
        func clock(_ minutes: Int) -> String {
            let wrapped = ((minutes % 1440) + 1440) % 1440
            return String(format: "%02d:%02d", wrapped / 60, wrapped % 60)
        }
        return "\(clock(startMinutes))–\(clock(endMinutes))"
    }
}

struct ManagedItem: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    /// "Series", "Movie", … as Jellyfin names item types.
    let type: String?
    let productionYear: Int?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case productionYear = "ProductionYear"
    }
}

/// Whether an item airs on one channel daypart, and why.
enum ChannelMembershipState: String, Codable, Equatable {
    /// Added by hand; the client may remove it.
    case added = "Added"
    /// In the daypart's resolved snapshot through a rule (genre, library,
    /// another collection) — not removable from the client.
    case viaRule = "ViaRule"
    case none = "None"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // An unknown state from a newer plugin is treated as "not on the
        // channel" rather than failing the whole menu.
        self = ChannelMembershipState(rawValue: raw) ?? .none
    }
}

struct ChannelMembership: Codable, Equatable {
    let channelId: String
    let daypartIndex: Int
    let state: ChannelMembershipState
    let ruleSummary: String?

    enum CodingKeys: String, CodingKey {
        case channelId = "ChannelId"
        case daypartIndex = "DaypartIndex"
        case state = "State"
        case ruleSummary = "RuleSummary"
    }
}

// MARK: - Request bodies

struct CreateManagedChannelRequest: Encodable, Equatable {
    let name: String
    let logo: String?
    let seedItemId: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case logo = "Logo"
        case seedItemId = "SeedItemId"
    }
}

/// A PATCH: only the fields that are set are sent. A `logo` of "" removes
/// the channel's logo; nil leaves it as it is.
struct UpdateManagedChannelRequest: Encodable, Equatable {
    var name: String?
    var logo: String?

    static let noLogo = ""

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case logo = "Logo"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(logo, forKey: .logo)
    }
}

struct AddChannelItemRequest: Encodable, Equatable {
    let itemId: String
    let daypartIndex: Int?

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case daypartIndex = "DaypartIndex"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(itemId, forKey: .itemId)
        // Omitted rather than null: the server picks the channel's default daypart.
        try container.encodeIfPresent(daypartIndex, forKey: .daypartIndex)
    }
}

/// ASP.NET's error body. The plugin puts its explanation in `detail`.
enum ProblemDetails {
    private struct Body: Decodable {
        let detail: String?
    }

    /// The server's own words for a refusal, or nil when the body has none.
    static func message(in data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        if let detail = body.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            return detail
        }
        return nil
    }
}

// MARK: - Add to Channel menu

/// One choosable line in the Add to Channel menu: a whole channel, or one
/// daypart of a scheduled channel.
struct ChannelMenuOption: Identifiable, Equatable {
    enum Action: Equatable {
        /// Add to the daypart; nil lets the server choose the channel's default.
        case add(daypartIndex: Int?)
        case remove(daypartIndex: Int?)
        /// On the channel through a rule — shown checked, but cannot be toggled here.
        case none
    }

    let channelId: String
    let daypartIndex: Int?
    let title: String
    let state: ChannelMembershipState
    let ruleSummary: String?

    var id: String { "\(channelId)#\(daypartIndex.map(String.init) ?? "-")" }

    var isChecked: Bool { state != .none }
    var isEnabled: Bool { state != .viaRule }

    /// "(via Science Fiction)" for a rule-sourced checkmark.
    var viaLabel: String? {
        guard state == .viaRule else { return nil }
        guard let ruleSummary, !ruleSummary.isEmpty else { return "(via a rule)" }
        return "(via \(ruleSummary))"
    }

    var action: Action {
        switch state {
        case .added: return .remove(daypartIndex: daypartIndex)
        case .none: return .add(daypartIndex: daypartIndex)
        case .viaRule: return .none
        }
    }
}

/// A channel's entry in the Add to Channel menu.
struct ChannelMenuEntry: Identifiable, Equatable {
    let channel: ManagedChannel
    /// The channel as one toggle (unscheduled channels).
    let single: ChannelMenuOption?
    /// One toggle per daypart (scheduled channels), picked from a sub-menu.
    let dayparts: [ChannelMenuOption]

    var id: String { channel.id }
    var isScheduled: Bool { single == nil }

    /// Checked in the top-level list when any of its dayparts carries the item.
    var isChecked: Bool { single?.isChecked ?? dayparts.contains(where: \.isChecked) }

    /// Build the menu from the channel list and the item's memberships.
    ///
    /// An unscheduled channel has a single daypart, but its state is folded
    /// across whatever memberships came back so a channel with an added title
    /// in any daypart reads as Added: Added beats ViaRule beats None.
    static func build(channels: [ManagedChannel], memberships: [ChannelMembership]) -> [ChannelMenuEntry] {
        let byChannel = Dictionary(grouping: memberships, by: \.channelId)
        return channels.map { channel in
            let rows = byChannel[channel.id] ?? []
            if channel.isScheduled {
                let options = channel.dayparts.map { daypart in
                    let membership = rows.first { $0.daypartIndex == daypart.index }
                    return ChannelMenuOption(
                        channelId: channel.id,
                        daypartIndex: daypart.index,
                        title: daypart.name,
                        state: membership?.state ?? .none,
                        ruleSummary: membership?.ruleSummary ?? daypart.ruleSummary
                    )
                }
                return ChannelMenuEntry(channel: channel, single: nil, dayparts: options)
            }

            let added = rows.first { $0.state == .added }
            let viaRule = rows.first { $0.state == .viaRule }
            let state: ChannelMembershipState = added != nil ? .added : (viaRule != nil ? .viaRule : .none)
            let option = ChannelMenuOption(
                channelId: channel.id,
                // Removal names the daypart it was added to; adding leaves the
                // choice to the server's default.
                daypartIndex: added?.daypartIndex,
                title: channel.name,
                state: state,
                ruleSummary: viaRule?.ruleSummary
            )
            return ChannelMenuEntry(channel: channel, single: option, dayparts: [])
        }
    }
}

/// What the Add to Channel action targets for a detail page's item: a series
/// for its episodes and seasons, otherwise the item itself.
struct ChannelTarget: Equatable, Identifiable {
    let itemId: String
    let title: String

    var id: String { itemId }

    init(itemId: String, title: String) {
        self.itemId = itemId
        self.title = title
    }

    /// Nil for item types a channel cannot air (people, folders, …).
    init?(item: BaseItemDto) {
        switch item.type {
        case .series:
            self.init(itemId: item.id, title: item.name)
        case .episode, .season:
            guard let seriesId = item.seriesId else { return nil }
            self.init(itemId: seriesId, title: item.seriesName ?? item.name)
        case .movie, .video:
            self.init(itemId: item.id, title: item.name)
        default:
            return nil
        }
    }
}

extension Notification.Name {
    /// A channel was created, renamed, deleted, or had titles added or
    /// removed: anything showing SashimiTV channels should reload.
    static let sashimiChannelsDidChange = Notification.Name("sashimiChannelsDidChange")
}

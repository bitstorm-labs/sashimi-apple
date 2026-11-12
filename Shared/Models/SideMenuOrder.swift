import Foundation

/// The one order Settings › Home & Side Menu edits on tvOS, iPad and Mac (#841).
///
/// Home's rows stay saved exactly as before, in each target's row config, and
/// Home never sees anything else. The side menu also lists entries that are
/// not Home rows: Lists (shared lists) and the libraries Home has no row for
/// (Collections, Playlists). Their places among the rows are a separate saved
/// list of keys, the whole combined order with the rows included, so each
/// menu-only entry can be put back after whatever it followed even when rows
/// come and go around it.
///
/// With nothing saved (every install from before #841), the menu-only entries
/// follow the rows: libraries in server order, then Lists. That is where the
/// side menu has always listed them, so nothing moves until the user moves it.
enum SideMenuOrder {
    enum Entry: Hashable {
        /// A Home row, by its config id.
        case row(String)
        /// A side-menu entry Home has no row for.
        case menuOnly(RailOrder.Destination)
    }

    /// One Home row as the side menu sees it: its config id, and the menu
    /// entry it stands for (nil for Featured, Continue Watching, shared-list
    /// rows; `.requests` for the Requests row, #861).
    struct Row: Equatable {
        let id: String
        let destination: RailOrder.Destination?
    }

    /// The side menu's entries that are not Home rows, in their default order:
    /// the Watchlist if `available` (#894), the libraries Home has no row for
    /// (server order), then Lists, then whichever of Requests and Dashboard
    /// are `available` (#845, see `RailOrder.conditionalDestinations`).
    /// A destination a row stands for is never also menu-only: Requests has
    /// a row on Home (#861), so a row order with it lists Requests once.
    static func menuOnly(rows: [Row], libraryIds: [String], available: [RailOrder.Destination] = []) -> [RailOrder.Destination] {
        let onHome = Set(rows.compactMap(\.destination))
        let conditional = RailOrder.trailingDestinations.filter { $0 != .lists && available.contains($0) }
        let watchlist: [RailOrder.Destination] = available.contains(.watchlist) ? [.watchlist] : []
        return (watchlist + libraryIds.map(RailOrder.Destination.library) + [.lists] + conditional)
            .filter { !onHome.contains($0) }
    }

    /// Whether Settings lists this row now: a row standing for Requests only
    /// while Seerr is `available`, the same rule as its menu entry (#861).
    static func isListed(_ row: Row, available: [RailOrder.Destination]) -> Bool {
        guard let destination = row.destination, RailOrder.isConditional(destination) else { return true }
        return available.contains(destination)
    }

    /// iPhone's Row Order (no side menu): Home's rows Settings lists now.
    static func rowEntries(rows: [Row], available: [RailOrder.Destination] = []) -> [Entry] {
        rows.filter { isListed($0, available: available) }.map { .row($0.id) }
    }

    /// Home's rows, in their own order, with the menu-only entries among them.
    ///
    /// A saved menu-only entry goes straight after the nearest entry it
    /// followed that is still here (the start, if none is). One the saved
    /// order has never seen (all of them before #841, a library added on the
    /// server later) goes at the end, except the Watchlist, which goes first:
    /// directly under Search, where it is new (#894). A saved entry that is no longer
    /// menu-only (the library left the server, or Home gained a row for it)
    /// is ignored.
    ///
    /// Requests and Dashboard are listed only while `available`; saved
    /// while signed in and absent now, they are skipped like a library
    /// that left the server. The Requests row is left out the same way, and
    /// `reordered` keeps it where it was when the others move.
    static func entries(rows: [Row], libraryIds: [String], saved: [String]?, available: [RailOrder.Destination] = []) -> [Entry] {
        var result = rowEntries(rows: rows, available: available)
        var unplaced = menuOnly(rows: rows, libraryIds: libraryIds, available: available)

        let savedEntries = (saved ?? []).map(Entry.init(storageKey:))
        for (index, entry) in savedEntries.enumerated() {
            guard case .menuOnly(let destination) = entry, unplaced.contains(destination) else { continue }
            let anchor = savedEntries[..<index].reversed().lazy.compactMap { result.firstIndex(of: $0) }.first
            result.insert(entry, at: anchor.map { $0 + 1 } ?? 0)
            unplaced.removeAll { $0 == destination }
        }

        if unplaced.first == .watchlist {
            // Never saved: an order from before the Watchlist, or none at all.
            result.insert(.menuOnly(.watchlist), at: 0)
            unplaced.removeFirst()
        }
        return result + unplaced.map(Entry.menuOnly)
    }

    /// What the side menu lists between its fixed entries, in the order
    /// Settings shows, less what the user hid from it (#753).
    static func destinations(
        rows: [Row],
        libraryIds: [String],
        saved: [String]?,
        hidden: Set<RailOrder.Destination> = [],
        available: [RailOrder.Destination] = []
    ) -> [RailOrder.Destination] {
        // Lists (and Requests, Dashboard) the user never moved are left to
        // RailOrder, which puts them last as it always has, behind a
        // SashimiTV the rows have not placed yet.
        let savedKeys = Set(saved ?? [])
        let order = entries(rows: rows, libraryIds: libraryIds, saved: saved, available: available)
            .compactMap { entry -> RailOrder.Destination? in
                switch entry {
                case .row(let id):
                    return rows.first { $0.id == id }?.destination
                case .menuOnly(let destination) where RailOrder.trailingDestinations.contains(destination):
                    return savedKeys.contains(entry.storageKey) ? destination : nil
                case .menuOnly(let destination):
                    return destination
                }
            }
        return RailOrder.destinations(rowOrder: order, libraryIds: libraryIds, hidden: hidden, available: available)
    }

    /// `entries` with the ones at `source` moved to `destination`, as
    /// `Array.move(fromOffsets:toOffset:)` does (SwiftUI's, kept out of Shared models).
    static func moving(_ entries: [Entry], from source: IndexSet, to destination: Int) -> [Entry] {
        let valid = source.filter { entries.indices.contains($0) }
        let moved = valid.map { entries[$0] }
        var result = entries
        for index in valid.reversed() { result.remove(at: index) }
        let target = destination - valid.filter { $0 < destination }.count
        result.insert(contentsOf: moved, at: min(max(target, 0), result.count))
        return result
    }

    /// The keys to save for `entries`.
    static func savedKeys(_ entries: [Entry]) -> [String] {
        entries.map(\.storageKey)
    }

    /// `rows` in the order `entries` puts them. A row `entries` does not
    /// mention (Requests while signed out of Seerr, #861) stays straight
    /// after the row it followed, or first if it led.
    static func reordered<Config>(_ rows: [Config], id: (Config) -> String, by entries: [Entry]) -> [Config] {
        let order = entries.compactMap { entry -> String? in
            if case .row(let rowId) = entry { return rowId }
            return nil
        }
        let ids = rows.map(id)
        var result = order.compactMap { ids.firstIndex(of: $0) }
        for index in ids.indices where !order.contains(ids[index]) {
            // Straight after the nearest row before it that is placed.
            let anchor = (0..<index).reversed().first { result.contains($0) }
            result.insert(index, at: anchor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
        return result.map { rows[$0] }
    }
}

extension SideMenuOrder.Entry {
    /// Marks a menu-only key. No Home row id starts with it: rows are
    /// built-in raw values, library ids/`library_` ids and `list_` ids.
    static let menuOnlyPrefix = "menu:"

    var storageKey: String {
        switch self {
        case .row(let id): return id
        case .menuOnly(let destination): return Self.menuOnlyPrefix + destination.storageKey
        }
    }

    init(storageKey: String) {
        if storageKey.hasPrefix(Self.menuOnlyPrefix),
           let destination = RailOrder.Destination(storageKey: String(storageKey.dropFirst(Self.menuOnlyPrefix.count))) {
            self = .menuOnly(destination)
        } else {
            self = .row(storageKey)
        }
    }
}

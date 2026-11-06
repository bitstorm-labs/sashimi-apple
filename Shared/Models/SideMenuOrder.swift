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
    /// entry it stands for (nil for Featured, Continue Watching, shared-list rows).
    struct Row: Equatable {
        let id: String
        let destination: RailOrder.Destination?
    }

    /// The side menu's entries that are not Home rows, in their default order:
    /// the libraries Home has no row for (server order), then Lists.
    static func menuOnly(rows: [Row], libraryIds: [String]) -> [RailOrder.Destination] {
        let onHome = Set(rows.compactMap(\.destination))
        return libraryIds.map(RailOrder.Destination.library).filter { !onHome.contains($0) } + [.lists]
    }

    /// Home's rows, in their own order, with the menu-only entries among them.
    ///
    /// A saved menu-only entry goes straight after the nearest entry it
    /// followed that is still here (the start, if none is). One the saved
    /// order has never seen (all of them before #841, a library added on the
    /// server later) goes at the end. A saved entry that is no longer
    /// menu-only (the library left the server, or Home gained a row for it)
    /// is ignored.
    static func entries(rows: [Row], libraryIds: [String], saved: [String]?) -> [Entry] {
        var result = rows.map { Entry.row($0.id) }
        var unplaced = menuOnly(rows: rows, libraryIds: libraryIds)

        let savedEntries = (saved ?? []).map(Entry.init(storageKey:))
        for (index, entry) in savedEntries.enumerated() {
            guard case .menuOnly(let destination) = entry, unplaced.contains(destination) else { continue }
            let anchor = savedEntries[..<index].reversed().lazy.compactMap { result.firstIndex(of: $0) }.first
            result.insert(entry, at: anchor.map { $0 + 1 } ?? 0)
            unplaced.removeAll { $0 == destination }
        }

        return result + unplaced.map(Entry.menuOnly)
    }

    /// What the side menu lists between its fixed entries, in the order
    /// Settings shows, less what the user hid from it (#753).
    static func destinations(
        rows: [Row],
        libraryIds: [String],
        saved: [String]?,
        hidden: Set<RailOrder.Destination> = []
    ) -> [RailOrder.Destination] {
        // Lists the user never moved is left to RailOrder, which puts it last
        // as it always has, behind a SashimiTV the rows have not placed yet.
        let listsPlaced = saved?.contains(Entry.menuOnly(.lists).storageKey) == true
        let order = entries(rows: rows, libraryIds: libraryIds, saved: saved).compactMap { entry -> RailOrder.Destination? in
            switch entry {
            case .row(let id): return rows.first { $0.id == id }?.destination
            case .menuOnly(.lists): return listsPlaced ? .lists : nil
            case .menuOnly(let destination): return destination
            }
        }
        return RailOrder.destinations(rowOrder: order, libraryIds: libraryIds, hidden: hidden)
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

    /// `rows` in the order `entries` puts them; rows `entries` does not
    /// mention keep their relative order after the rest.
    static func reordered<Config>(_ rows: [Config], id: (Config) -> String, by entries: [Entry]) -> [Config] {
        let order = entries.compactMap { entry -> String? in
            if case .row(let rowId) = entry { return rowId }
            return nil
        }
        let ranked = rows.enumerated().map { offset, row in
            (rank: order.firstIndex(of: id(row)) ?? order.count + offset, row: row)
        }
        return ranked.sorted { $0.rank < $1.rank }.map(\.row)
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

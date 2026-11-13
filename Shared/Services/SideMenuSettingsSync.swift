import Combine
import Foundation

/// A device's side menu as the `sideMenu` sync value (WORK-106 phase 2,
/// plans/sashimi/2026-11-12-settings-sync-schema.md). Each app target
/// supplies its stored state; the rules (what the combined order is, what
/// counts as customised, how a remote value lands) live in the extension
/// below so tvOS and iPhone/iPad/Mac share them.
///
/// The value is the side menu's whole combined order: Home's rows and the
/// menu-only entries interleaved, Home and Settings never in it. Rows use the
/// `homeRows` shared ids; destinations (`RailOrder.Destination.storageKey`)
/// carry `menu`, whether the side menu shows them.
@MainActor
protocol SettingsSyncSideMenuSource: AnyObject {
    /// Where the stamp is kept. Per server where the order is.
    var stampKey: String { get }
    /// Home's rows in their order, as the side menu sees them; nil while the
    /// device doesn't know them yet.
    func currentRows() -> [SideMenuOrder.Row]?
    /// `SideMenuOrder` keys as saved, nil until something was moved.
    var savedOrder: [String]? { get }
    /// What the user took out of the side menu.
    var hidden: Set<RailOrder.Destination> { get }
    /// The destinations this platform can list besides Search, Lists,
    /// SashimiTV and libraries (Downloads only on iPhone/iPad/Mac).
    var platformDestinations: [RailOrder.Destination] { get }
    /// A local row id as a shared id, and back (nil: no such row here).
    func sharedRowId(_ localId: String) -> String
    /// Saves a combined order (rows reordered with it; empty: the order is
    /// unchanged) and the menu switches in `shown`.
    func applySideMenu(_ entries: [SideMenuOrder.Entry], shown: [RailOrder.Destination: Bool])
    /// Fires after the rows, the saved order or the hidden set change
    /// (delivered later on the main queue).
    var changes: AnyPublisher<Void, Never> { get }
}

extension SettingsSyncSideMenuSource {
    /// The menu's entries as Settings shows them, every destination this
    /// platform has counted as available: menu-only libraries are the ones
    /// the saved order or the hidden set names (the server's full library
    /// list isn't known here).
    func currentEntries(rows: [SideMenuOrder.Row]) -> [SideMenuOrder.Entry] {
        var libraryIds: [String] = []
        let named = rows.compactMap(\.destination)
            + (savedOrder ?? []).compactMap { key -> RailOrder.Destination? in
                if case .menuOnly(let destination) = SideMenuOrder.Entry(storageKey: key) { return destination }
                return nil
            }
            + hidden.sorted { $0.storageKey < $1.storageKey }
        for case .library(let id) in named where !libraryIds.contains(id) {
            libraryIds.append(id)
        }
        return SideMenuOrder.entries(rows: rows, libraryIds: libraryIds, saved: savedOrder, available: platformDestinations)
    }

    /// The `sideMenu` value for this device now.
    func currentLayout() -> [SettingsSync.MenuEntry]? {
        guard let rows = currentRows() else { return nil }
        return layout(currentEntries(rows: rows), rows: rows)
    }

    private func layout(_ entries: [SideMenuOrder.Entry], rows: [SideMenuOrder.Row]) -> [SettingsSync.MenuEntry] {
        let hidden = self.hidden
        return entries.map { entry in
            switch entry {
            case .row(let id):
                let destination = rows.first { $0.id == id }?.destination
                return SettingsSync.MenuEntry(id: sharedRowId(id), menu: destination.map { !hidden.contains($0) })
            case .menuOnly(let destination):
                return SettingsSync.MenuEntry(id: destination.storageKey, menu: !hidden.contains(destination))
            }
        }
    }

    /// What a local edit changes: the saved order and the hidden set. Rows
    /// moving on their own (iPhone's Row Order, a new library) and Search
    /// arriving by the migration change neither, so they are not edits.
    var editSignature: String {
        SettingsSync.encodeValue(.menuLayout(
            (savedOrder ?? []).map { SettingsSync.MenuEntry(id: $0) }
                + hidden.map(\.storageKey).sorted().map { SettingsSync.MenuEntry(id: $0, menu: false) }
        ))
    }

    /// Seeding: only when the user clearly customised the menu, some entry
    /// hidden or the order not the platform default (Search, Watchlist,
    /// SashimiTV, libraries in any order, Lists, Requests, Dashboard,
    /// Downloads).
    var isCustomised: Bool {
        guard let rows = currentRows() else { return false }
        if !hidden.isEmpty { return true }
        // Requests is left out: a row order saved before #861 has it under
        // Continue Watching, where the app put it, not the user. Dashboard
        // and Downloads only count if moved up from the end: an order saved
        // before one of them was available has them the other way round.
        let order: [RailOrder.Destination] = currentEntries(rows: rows).compactMap { entry in
            switch entry {
            case .row(let id): return rows.first { $0.id == id }?.destination
            case .menuOnly(let destination): return destination
            }
        }.filter { $0 != .requests }
        let late: [RailOrder.Destination] = [.dashboard, .downloads]
        let main = order.filter { !late.contains($0) }
        if let lastMain = main.last.flatMap(order.lastIndex(of:)),
           order.indices.contains(where: { late.contains(order[$0]) && $0 < lastMain }) {
            return true
        }
        let libraries = main.filter { if case .library = $0 { return true }; return false }
        let fallback: [RailOrder.Destination] = [.search, .watchlist, .finTV] + libraries + [.lists]
        return main != fallback.filter(main.contains)
    }

    /// The entries now, before a remote `homeRows` moves the rows
    /// (`keepMenuSlots`); nil while the rows aren't known.
    func entriesBeforeRowsMove() -> [SideMenuOrder.Entry]? {
        currentRows().map(currentEntries(rows:))
    }

    /// After a remote `homeRows` moved the rows: the rows take the slots rows
    /// held in `previous`, in their new order, and every menu-only entry
    /// stays exactly where it was (`SideMenuOrder` alone would carry it
    /// along with the row it follows). Rows that came or went are left to
    /// `SideMenuOrder`.
    func keepMenuSlots(of previous: [SideMenuOrder.Entry]) {
        guard let rows = currentRows() else { return }
        let previousRows = Set(previous.compactMap { entry -> String? in
            if case .row(let id) = entry { return id }
            return nil
        })
        var ordered = rows.map(\.id).filter(previousRows.contains).makeIterator()
        let kept = previous.map { entry -> SideMenuOrder.Entry in
            guard case .row = entry, let next = ordered.next() else { return entry }
            return .row(next)
        }
        guard kept != currentEntries(rows: rows) else { return }
        applySideMenu(kept, shown: [:])
    }

    /// Applies a remote `sideMenu` value. Entries this device has (and
    /// menu-only libraries it may have: saving their place is harmless)
    /// take the remote order and `menu`; the rest stay after what they
    /// follow; ids it doesn't know are skipped. With `rowsFromMenu` false
    /// (`homeRows` is the newer order) the rows keep their order here and
    /// only the menu-only entries move. Never touches Home's on/off.
    func apply(remote: [SettingsSync.MenuEntry], rowsFromMenu: Bool) {
        guard let rows = currentRows() else { return }
        let entries = currentEntries(rows: rows)
        let local = layout(entries, rows: rows)
        let localRows = Dictionary(rows.map { (sharedRowId($0.id), $0) }, uniquingKeysWith: { first, _ in first })

        // Menu-only libraries the remote places that aren't listed here yet.
        let widened = SettingsSync.writeOrder(local: local, remote: remote, id: \.id) { entry in
            entry.id.hasPrefix("library:") && RailOrder.Destination(storageKey: entry.id) != nil
        }
        let flags = Dictionary(remote.compactMap { entry in entry.menu.map { (entry.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        var merged = SettingsSync.applyOrder(local: widened, remote: remote, id: \.id).map { entry in
            let mine = widened.first { $0.id == entry.id }
            // `menu` only for what is a destination here, and only where the
            // remote said so.
            let isDestination = localRows[entry.id].map { $0.destination != nil } ?? true
            guard isDestination, let flag = flags[entry.id] else { return mine ?? entry }
            return SettingsSync.MenuEntry(id: entry.id, menu: flag)
        }
        if !rowsFromMenu {
            // The rows' slots, filled in this device's row order.
            var ordered = local.filter { localRows[$0.id] != nil }.makeIterator()
            merged = merged.map { localRows[$0.id] != nil ? ordered.next() ?? $0 : $0 }
        }

        var shown: [RailOrder.Destination: Bool] = [:]
        let newEntries: [SideMenuOrder.Entry] = merged.compactMap { entry in
            let result: SideMenuOrder.Entry
            let destination: RailOrder.Destination?
            if let row = localRows[entry.id] {
                result = .row(row.id)
                destination = row.destination
            } else if let parsed = RailOrder.Destination(storageKey: entry.id) {
                result = .menuOnly(parsed)
                destination = parsed
            } else {
                return nil
            }
            if let destination, let menu = entry.menu, menu == hidden.contains(destination) {
                shown[destination] = menu
            }
            return result
        }
        guard newEntries != entries || !shown.isEmpty else { return }
        applySideMenu(newEntries == entries ? [] : newEntries, shown: shown)
    }
}

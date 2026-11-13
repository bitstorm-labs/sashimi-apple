import Combine
import Foundation

/// iPhone/iPad/Mac Home rows as the `homeRows` sync value (WORK-106). The
/// rows are `HomeRowSettings.rows`, kept per server, so the stamp is too.
/// There is no hero row here; another device's hero entry is carried through.
@MainActor
final class HomeRowsSettingsSync: SettingsSyncLayoutSource {
    private let settings: HomeRowSettings
    private let activeServerID: @MainActor () -> String?

    /// `settings` nil: `HomeRowSettings.shared` (a default argument can't
    /// name the main-actor singleton).
    init(settings: HomeRowSettings? = nil,
         activeServerID: @escaping @MainActor () -> String? = { SessionManager.shared.activeServerId }) {
        self.settings = settings ?? .shared
        self.activeServerID = activeServerID
    }

    var stampKey: String {
        settings.serverID.map { "\(SettingsSync.homeRowsKey).\($0)" } ?? SettingsSync.homeRowsKey
    }

    /// Whether `HomeRowSettings` ever saved rows for this server (its
    /// `homeRowOrder.<server>` key, or the pre-multi-server `homeRowOrder`).
    var isExplicit: Bool {
        let defaults = UserDefaults.standard
        let legacy = "homeRowOrder"
        return defaults.object(forKey: settings.serverID.map { "\(legacy).\($0)" } ?? legacy) != nil
            || defaults.object(forKey: legacy) != nil
    }

    func currentLayout() -> [SettingsSync.LayoutEntry]? {
        // A sync can run on a server switch before Home has switched the
        // rows; never read (or write) the previous server's rows for it.
        settings.use(serverID: activeServerID())
        return settings.rows.isEmpty ? nil : Self.layout(settings.rows)
    }

    func apply(_ layout: [SettingsSync.LayoutEntry]) {
        let applied = Self.rows(settings.rows, applying: layout)
        guard applied != settings.rows else { return }
        settings.rows = applied
        settings.saveRows()
    }

    var changes: AnyPublisher<Void, Never> {
        // @Published fires before the new value is stored; read it after.
        settings.$rows.map { _ in }.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    static func layout(_ rows: [HomeRowConfig]) -> [SettingsSync.LayoutEntry] {
        rows.map { SettingsSync.LayoutEntry(id: SettingsSync.RowIds.shared(mobile: $0.id), on: $0.isEnabled) }
    }

    static func rows(_ rows: [HomeRowConfig], applying layout: [SettingsSync.LayoutEntry]) -> [HomeRowConfig] {
        let ordered = SettingsSync.applyLayout(local: self.layout(rows), remote: layout)
        return ordered.compactMap { entry in
            guard var row = rows.first(where: { SettingsSync.RowIds.shared(mobile: $0.id) == entry.id }) else { return nil }
            row.isEnabled = entry.on
            return row
        }
    }
}

/// iPhone/iPad/Mac side menu as the `sideMenu` sync value (WORK-106 phase 2):
/// `HomeRowSettings.sideMenuOrder` (per server, like the rows) and
/// `SideMenuSettings.hidden`. iPhone has no side menu to edit, but applies
/// and keeps the value like iPad, so it never drops it on a write.
@MainActor
final class SideMenuSettingsSync: SettingsSyncSideMenuSource {
    private let settings: HomeRowSettings
    private let menu: SideMenuSettings
    private let activeServerID: @MainActor () -> String?

    init(settings: HomeRowSettings? = nil, menu: SideMenuSettings? = nil,
         activeServerID: @escaping @MainActor () -> String? = { SessionManager.shared.activeServerId }) {
        self.settings = settings ?? .shared
        self.menu = menu ?? .shared
        self.activeServerID = activeServerID
    }

    var stampKey: String {
        settings.serverID.map { "\(SettingsSync.sideMenuKey).\($0)" } ?? SettingsSync.sideMenuKey
    }

    func currentRows() -> [SideMenuOrder.Row]? {
        // Never the previous server's order on a server switch.
        settings.use(serverID: activeServerID())
        return settings.rows.isEmpty ? nil : settings.rows.map(\.sideMenuRow)
    }

    var savedOrder: [String]? { settings.sideMenuOrder }

    var hidden: Set<RailOrder.Destination> { menu.hidden }

    let platformDestinations: [RailOrder.Destination] = [.watchlist, .requests, .dashboard, .downloads]

    func sharedRowId(_ localId: String) -> String {
        SettingsSync.RowIds.shared(mobile: localId)
    }

    func applySideMenu(_ entries: [SideMenuOrder.Entry], shown: [RailOrder.Destination: Bool]) {
        if !entries.isEmpty { settings.applySideMenuOrder(entries) }
        for (destination, isShown) in shown { menu.setShown(isShown, for: destination) }
    }

    var changes: AnyPublisher<Void, Never> {
        Publishers.Merge3(settings.$rows.map { _ in }, settings.$sideMenuOrder.map { _ in }, menu.$hidden.map { _ in })
            .receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }
}

import Combine
import Foundation

/// tvOS Home rows as the `homeRows` sync value (WORK-106). The rows are
/// `HomeScreenSettings.rowConfigs`, one layout for every server.
@MainActor
final class HomeRowsSettingsSync: SettingsSyncLayoutSource {
    private let settings: HomeScreenSettings
    private let defaults: UserDefaults

    /// `settings` nil: `HomeScreenSettings.shared` (a default argument can't
    /// name the main-actor singleton).
    init(settings: HomeScreenSettings? = nil, defaults: UserDefaults = .standard) {
        self.settings = settings ?? .shared
        self.defaults = defaults
    }

    let stampKey = SettingsSync.homeRowsKey

    /// `HomeScreenSettings`' saved row order (its private `userDefaultsKey`).
    static let savedRowsKey = "homeScreenRowOrder"

    var isExplicit: Bool { defaults.object(forKey: Self.savedRowsKey) != nil }

    func currentLayout() -> [SettingsSync.LayoutEntry]? {
        let rows = settings.rowConfigs
        guard !rows.isEmpty else { return nil }
        return Self.layout(rows)
    }

    func apply(_ layout: [SettingsSync.LayoutEntry]) {
        let applied = Self.rows(settings.rowConfigs, applying: layout)
        guard applied != settings.rowConfigs else { return }
        settings.rowConfigs = applied
        settings.saveSettings()
    }

    var changes: AnyPublisher<Void, Never> {
        // @Published fires before the new value is stored; read it after.
        settings.$rowConfigs.map { _ in }.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    static func layout(_ rows: [HomeRowConfig]) -> [SettingsSync.LayoutEntry] {
        rows.map { SettingsSync.LayoutEntry(id: SettingsSync.RowIds.shared(tvOS: $0.id), on: $0.isVisible) }
    }

    /// `rows` in `layout`'s order with its on/off; a row it lacks keeps its
    /// place after the row it follows (`SettingsSync.applyLayout`).
    static func rows(_ rows: [HomeRowConfig], applying layout: [SettingsSync.LayoutEntry]) -> [HomeRowConfig] {
        let ordered = SettingsSync.applyLayout(local: self.layout(rows), remote: layout)
        return ordered.compactMap { entry in
            guard var row = rows.first(where: { SettingsSync.RowIds.shared(tvOS: $0.id) == entry.id }) else { return nil }
            row.isVisible = entry.on
            return row
        }
    }
}

/// tvOS side menu as the `sideMenu` sync value (WORK-106 phase 2): the order
/// `HomeScreenSettings.sideMenuOrder` saves among `rowConfigs`, and
/// `SideMenuSettings.hidden`. One for every server, like the rows.
@MainActor
final class SideMenuSettingsSync: SettingsSyncSideMenuSource {
    private let settings: HomeScreenSettings
    private let menu: SideMenuSettings

    init(settings: HomeScreenSettings? = nil, menu: SideMenuSettings? = nil) {
        self.settings = settings ?? .shared
        self.menu = menu ?? .shared
    }

    let stampKey = SettingsSync.sideMenuKey

    func currentRows() -> [SideMenuOrder.Row]? {
        settings.rowConfigs.isEmpty ? nil : settings.rowConfigs.map(\.sideMenuRow)
    }

    var savedOrder: [String]? { settings.sideMenuOrder }

    var hidden: Set<RailOrder.Destination> { menu.hidden }

    /// No Downloads on tvOS: another device's is carried through.
    let platformDestinations: [RailOrder.Destination] = [.watchlist, .requests, .dashboard]

    func sharedRowId(_ localId: String) -> String {
        SettingsSync.RowIds.shared(tvOS: localId)
    }

    func applySideMenu(_ entries: [SideMenuOrder.Entry], shown: [RailOrder.Destination: Bool]) {
        if !entries.isEmpty { settings.applySideMenuOrder(entries) }
        for (destination, isShown) in shown { menu.setShown(isShown, for: destination) }
    }

    var changes: AnyPublisher<Void, Never> {
        Publishers.Merge3(settings.$rowConfigs.map { _ in }, settings.$sideMenuOrder.map { _ in }, menu.$hidden.map { _ in })
            .receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }
}

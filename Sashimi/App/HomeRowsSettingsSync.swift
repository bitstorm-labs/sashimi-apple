import Combine
import Foundation

/// tvOS Home rows as the `homeRows` sync value (WORK-106). The rows are
/// `HomeScreenSettings.rowConfigs`, one layout for every server.
@MainActor
final class HomeRowsSettingsSync: SettingsSyncLayoutSource {
    private let settings: HomeScreenSettings
    private let defaults: UserDefaults

    init(settings: HomeScreenSettings = .shared, defaults: UserDefaults = .standard) {
        self.settings = settings
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

import Foundation
import SwiftUI

enum HomeRowType: String, Codable, Identifiable, CaseIterable {
    case continueWatching = "continue_watching"
    // Added after release. loadRows() appends any built-in the saved config
    // lacks, so existing users gain the row without a bespoke migration, and
    // the raw value must never change once shipped.
    case channels

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .continueWatching: return "Continue Watching"
        case .channels: return "FinTV"
        }
    }
}

struct HomeRowConfig: Codable, Identifiable, Equatable {
    let type: HomeRowConfigType
    var isEnabled: Bool

    var id: String {
        switch type {
        case .builtIn(let rowType): return rowType.rawValue
        case .library(let id, _): return id
        }
    }

    var displayName: String {
        switch type {
        case .builtIn(let rowType): return rowType.displayName
        case .library(_, let name): return "Recently Added \(name)"
        }
    }
}

enum HomeRowConfigType: Codable, Equatable {
    case builtIn(HomeRowType)
    case library(id: String, name: String)
}

@MainActor
final class HomeRowSettings: ObservableObject {
    static let shared = HomeRowSettings()

    @Published var rows: [HomeRowConfig] = []

    private let userDefaultsKey = "homeRowOrder"

    private init() {
        loadRows()
    }

    func loadRows() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let savedRows = try? JSONDecoder().decode([HomeRowConfig].self, from: data) {
            rows = savedRows
            // A config saved before a built-in row existed has no entry for it.
            // Insert ahead of the library rows rather than appending: built-ins
            // lead on tvOS too, and a new row appended behind every library is
            // one the user has to go looking for.
            let firstLibrary = rows.firstIndex { if case .library = $0.type { return true }; return false }
            for type in HomeRowType.allCases where !savedRows.contains(where: {
                if case .builtIn(let saved) = $0.type { return saved == type }
                return false
            }) {
                let config = HomeRowConfig(type: .builtIn(type), isEnabled: true)
                if let firstLibrary {
                    rows.insert(config, at: firstLibrary)
                } else {
                    rows.append(config)
                }
            }
        } else {
            // Default order - just Continue Watching, libraries added dynamically
            rows = HomeRowType.allCases.map {
                HomeRowConfig(type: .builtIn($0), isEnabled: true)
            }
        }
    }

    func saveRows() {
        if let data = try? JSONEncoder().encode(rows) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    func updateLibraries(_ libraries: [JellyfinLibrary]) {
        // Add any new libraries that aren't in the list
        for library in libraries where !rows.contains(where: {
            if case .library(let id, _) = $0.type {
                return id == library.id
            }
            return false
        }) {
            rows.append(HomeRowConfig(type: .library(id: library.id, name: library.name), isEnabled: true))
        }

        // Remove libraries that no longer exist
        rows.removeAll { config in
            if case .library(let id, _) = config.type {
                return !libraries.contains(where: { $0.id == id })
            }
            return false
        }

        saveRows()
    }

    func moveRow(from source: IndexSet, to destination: Int) {
        rows.move(fromOffsets: source, toOffset: destination)
        saveRows()
    }

    func toggleRow(at index: Int) {
        rows[index].isEnabled.toggle()
        saveRows()
    }
}

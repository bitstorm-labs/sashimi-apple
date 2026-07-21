import Foundation
import SwiftUI

enum HomeRowType: String, Codable, Identifiable, CaseIterable {
    case hero = "hero"
    case continueWatching = "continue_watching"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hero: return "Featured (iPad)"
        case .continueWatching: return "Continue Watching"
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
            // Migration: configs saved before the hero row existed get it
            // injected up top (enabled — it's the new default look on iPad).
            if !rows.contains(where: { $0.type == .builtIn(.hero) }) {
                rows.insert(HomeRowConfig(type: .builtIn(.hero), isEnabled: true), at: 0)
                saveRows()
            }
        } else {
            // Default order - hero, Continue Watching; libraries added dynamically
            rows = [
                HomeRowConfig(type: .builtIn(.hero), isEnabled: true),
                HomeRowConfig(type: .builtIn(.continueWatching), isEnabled: true)
            ]
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

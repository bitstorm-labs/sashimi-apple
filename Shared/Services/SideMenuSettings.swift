import Foundation

/// What the user took out of the side menu (#753), per device. Kept apart
/// from the Home row config on purpose: the menu also lists libraries Home
/// has no row for (Collections, Playlists), and hiding something from one is
/// not hiding it from the other. Home, Search, Settings (and Downloads on
/// iPad/Mac) are not `RailOrder.Destination`s, so they can never be hidden.
/// Library ids are server GUIDs, so one set serves every server.
@MainActor
final class SideMenuSettings: ObservableObject {
    static let shared = SideMenuSettings()

    static let defaultsKey = "sideMenuHidden"

    @Published private(set) var hidden: Set<RailOrder.Destination>

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = Set((defaults.stringArray(forKey: Self.defaultsKey) ?? []).compactMap(RailOrder.Destination.init(storageKey:)))
    }

    func isShown(_ destination: RailOrder.Destination) -> Bool {
        !hidden.contains(destination)
    }

    func setShown(_ shown: Bool, for destination: RailOrder.Destination) {
        if shown { hidden.remove(destination) } else { hidden.insert(destination) }
        defaults.set(hidden.map(\.storageKey).sorted(), forKey: Self.defaultsKey)
    }

    func toggle(_ destination: RailOrder.Destination) {
        setShown(!isShown(destination), for: destination)
    }
}

extension RailOrder.Destination {
    var storageKey: String {
        switch self {
        case .finTV: return "fintv"
        case .lists: return "lists"
        case .library(let id): return "library:\(id)"
        }
    }

    init?(storageKey: String) {
        if storageKey == "fintv" {
            self = .finTV
        } else if storageKey == "lists" {
            self = .lists
        } else if storageKey.hasPrefix("library:") {
            self = .library(String(storageKey.dropFirst("library:".count)))
        } else {
            return nil
        }
    }
}

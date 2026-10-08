import Foundation

/// Routes menu-bar commands to whoever can carry them out: the player while
/// one is on screen, otherwise the rail navigation. The player and the
/// navigation register themselves; the menus only read `isEnabled` and call
/// `perform`.
@MainActor
final class AppCommandCenter: ObservableObject {
    static let shared = AppCommandCenter()

    /// The player on screen. Registered on appear, cleared on disappear (by
    /// id, so a player that is replacing another can't be cleared by the
    /// outgoing one's late disappear).
    struct PlayerTarget {
        let id: UUID
        /// For the Playback menu's state (episode availability, quality).
        weak var viewModel: PlayerViewModel?
        let perform: @MainActor (AppCommand) -> Void
    }

    /// A rail section to show, for `MainNavigationView` to carry out.
    struct NavigationRequest: Equatable {
        let id = UUID()
        let selection: SidebarSelection
        /// ⌘F: put the caret in the search field.
        var focusesSearch = false
    }

    @Published private(set) var player: PlayerTarget?
    /// The rail's destinations in drawing order. Empty while no rail is on
    /// screen (signed out, or the iPhone's tab layout).
    @Published private(set) var railItems: [SidebarSelection] = []
    @Published private(set) var navigationRequest: NavigationRequest?

    init() {}

    // MARK: Registration

    func registerPlayer(_ target: PlayerTarget) {
        player = target
    }

    func unregisterPlayer(id: UUID) {
        guard player?.id == id else { return }
        player = nil
    }

    func updateRailItems(_ items: [SidebarSelection]) {
        if railItems != items { railItems = items }
    }

    func consumeNavigationRequest(id: UUID) {
        guard navigationRequest?.id == id else { return }
        navigationRequest = nil
    }

    // MARK: Commands

    func isEnabled(_ command: AppCommand) -> Bool {
        if command.isPlayerCommand {
            return player != nil
        }
        // Navigation happens behind a player; keep it for when one isn't up.
        guard player == nil else { return false }
        switch command {
        case .railSection(let number):
            return RailShortcut.selection(forShortcut: number, in: railItems) != nil
        case .search:
            return railItems.contains(.search)
        case .settings:
            return railItems.contains(.settings)
        default:
            return false
        }
    }

    func perform(_ command: AppCommand) {
        guard isEnabled(command) else { return }
        if command.isPlayerCommand {
            player?.perform(command)
            return
        }
        switch command {
        case .railSection(let number):
            if let selection = RailShortcut.selection(forShortcut: number, in: railItems) {
                navigationRequest = NavigationRequest(selection: selection)
            }
        case .search:
            navigationRequest = NavigationRequest(selection: .search, focusesSearch: true)
        case .settings:
            navigationRequest = NavigationRequest(selection: .settings)
        default:
            break
        }
    }
}

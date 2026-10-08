import Foundation

/// Everything the menu bar (and its keyboard shortcuts) can ask the app to do.
/// The Mac app is the main user, but the same commands show in the iPad's
/// hardware-keyboard shortcut overlay. Pure values, so the routing below can
/// be tested without a window.
enum AppCommand: Equatable {
    // Playback (enabled only while the player is up)
    case playPause
    case skip(seconds: Double)
    case nextEpisode
    case previousEpisode
    case toggleSubtitles
    case toggleMute
    case setQuality(QualityOption)
    case toggleFullScreen
    /// Esc in the player: leave full screen if the window is full screen,
    /// otherwise close the player.
    case escape
    case closePlayer

    // Navigation
    /// ⌘1…⌘9: the nth rail destination, 1-based.
    case railSection(Int)
    case search
    case settings

    static let skipInterval: Double = 10

    /// Commands that act on the player. They are disabled while no player is
    /// up, which also stops their unmodified shortcuts (Space, arrows, F, M,
    /// Esc) from swallowing keystrokes meant for text fields.
    var isPlayerCommand: Bool {
        switch self {
        case .railSection, .search, .settings:
            return false
        default:
            return true
        }
    }
}

/// A menu command's key equivalent, independent of SwiftUI's key types so the
/// map can be tested.
struct CommandShortcut: Hashable {
    enum Key: Hashable {
        case space
        case leftArrow
        case rightArrow
        case escape
        case character(Character)
    }

    enum Modifier: Hashable {
        case command, shift, option, control
    }

    let key: Key
    var modifiers: Set<Modifier> = []
}

extension AppCommand {
    /// The player's keys are unmodified, as in QuickTime and every web
    /// player: Space plays/pauses, ←/→ skip 10 s, F full screen, M mute,
    /// C subtitles, Esc leaves full screen (or closes the player). They are
    /// safe unmodified only because player commands are disabled while no
    /// player is up (see `isPlayerCommand`).
    var shortcut: CommandShortcut? {
        switch self {
        case .playPause:
            return CommandShortcut(key: .space)
        case .skip(let seconds):
            return CommandShortcut(key: seconds < 0 ? .leftArrow : .rightArrow)
        case .nextEpisode:
            return CommandShortcut(key: .rightArrow, modifiers: [.command, .shift])
        case .previousEpisode:
            return CommandShortcut(key: .leftArrow, modifiers: [.command, .shift])
        case .toggleSubtitles:
            return CommandShortcut(key: .character("c"))
        case .toggleMute:
            return CommandShortcut(key: .character("m"))
        case .toggleFullScreen:
            return CommandShortcut(key: .character("f"))
        case .escape:
            return CommandShortcut(key: .escape)
        case .railSection(let number):
            guard (1...RailShortcut.maxShortcut).contains(number) else { return nil }
            return CommandShortcut(key: .character(Character(String(number))), modifiers: [.command])
        case .search:
            return CommandShortcut(key: .character("f"), modifiers: [.command])
        case .settings:
            return CommandShortcut(key: .character(","), modifiers: [.command])
        case .setQuality, .closePlayer:
            return nil
        }
    }
}

/// What Esc does in the player right now.
enum PlayerEscapeAction: Equatable {
    case exitFullScreen
    case closePlayer

    static func forWindow(isFullScreen: Bool) -> Self {
        isFullScreen ? .exitFullScreen : .closePlayer
    }
}

/// ⌘1…⌘9 over the rail's destinations, in the order the rail draws them.
/// ⌘1–⌘8 are the first eight; ⌘9 is the last (Safari's tab rule), so
/// Settings at the foot of a long rail keeps a shortcut however many
/// libraries the server has.
enum RailShortcut {
    static let maxShortcut = 9

    static func selection(forShortcut number: Int, in items: [SidebarSelection]) -> SidebarSelection? {
        guard let index = items.indices.first(where: { shortcutNumber(forIndex: $0, count: items.count) == number })
        else { return nil }
        return items[index]
    }

    /// The shortcut the menu shows for the rail item at `index`, if any.
    static func shortcutNumber(forIndex index: Int, count: Int) -> Int? {
        guard index >= 0, index < count else { return nil }
        if index < maxShortcut - 1 { return index + 1 }
        return index == count - 1 ? maxShortcut : nil
    }
}

/// "Toggle Subtitles": off when a track is on; when off, the track that was
/// on last in this session, else one in the preferred language, else the
/// first.
enum SubtitleToggle {
    enum Choice: Equatable {
        case off
        case track(id: String)
        /// Nothing to switch to (no subtitle tracks).
        case none
    }

    static func choice(
        tracks: [SubtitleTrackOption],
        selectedID: String?,
        lastSelectedID: String?,
        preferredLanguage: String
    ) -> Choice {
        let selectable = tracks.filter { !$0.isOffOption }
        if let selectedID, selectedID != "off", selectable.contains(where: { $0.id == selectedID }) {
            return .off
        }
        guard let first = selectable.first else { return .none }
        if let lastSelectedID, selectable.contains(where: { $0.id == lastSelectedID }) {
            return .track(id: lastSelectedID)
        }
        let preferred = preferredLanguage.lowercased()
        if !preferred.isEmpty,
           let match = selectable.first(where: { $0.languageCode?.lowercased() == preferred }) {
            return .track(id: match.id)
        }
        return .track(id: first.id)
    }
}

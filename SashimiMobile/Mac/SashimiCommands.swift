import SwiftUI

/// The menu bar: Settings (⌘,), rail sections in View (⌘1…⌘9), Go (⌘F
/// Search) and Playback. On iPad the same commands appear in the
/// hardware-keyboard shortcut overlay.
struct SashimiCommands: Commands {
    @ObservedObject var center: AppCommandCenter

    var body: some Commands {
        // No documents: drop the File menu's Duplicate / Rename / Export.
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .importExport) {}

        CommandGroup(replacing: .appSettings) {
            CommandButton(title: "Settings…", command: .settings, center: center)
        }

        // Rail sections sit in View, above the system's Enter Full Screen,
        // in place of "Show Sidebar" (the rail is not a hideable sidebar).
        CommandGroup(replacing: .sidebar) {
            RailSectionCommands(center: center)
        }

        CommandMenu("Go") {
            CommandButton(title: "Search", command: .search, center: center)
        }

        CommandMenu("Playback") {
            PlaybackCommands(center: center)
        }
    }
}

/// A menu item for one command, with its shortcut and enabled state.
private struct CommandButton: View {
    let title: String
    let command: AppCommand
    @ObservedObject var center: AppCommandCenter
    var isEnabled = true

    var body: some View {
        let button = Button(title) { center.perform(command) }
            .disabled(!isEnabled || !center.isEnabled(command))
        if let shortcut = command.shortcut {
            button.keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers)
        } else {
            button
        }
    }
}

private struct RailSectionCommands: View {
    @ObservedObject var center: AppCommandCenter

    var body: some View {
        let items = center.railItems
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            if let number = RailShortcut.shortcutNumber(forIndex: index, count: items.count) {
                CommandButton(title: item.displayName, command: .railSection(number), center: center)
            }
        }
        if !items.isEmpty {
            Divider()
        }
    }
}

/// The Playback menu. With a player up it observes the player's view model
/// so episode, subtitle and quality items track it; without one every item
/// is disabled.
private struct PlaybackCommands: View {
    @ObservedObject var center: AppCommandCenter

    var body: some View {
        if let viewModel = center.player?.viewModel {
            ObservedPlaybackCommands(center: center, viewModel: viewModel)
        } else {
            PlaybackMenuItems(center: center, state: .noPlayer)
        }
    }
}

private struct ObservedPlaybackCommands: View {
    @ObservedObject var center: AppCommandCenter
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        PlaybackMenuItems(
            center: center,
            state: PlaybackMenuState(
                canPlayPrevious: viewModel.transitionState.canPlayPrevious,
                canPlayNext: viewModel.transitionState.canPlayNext,
                hasSubtitles: viewModel.subtitleTracks.contains { !$0.isOffOption },
                selectedQuality: viewModel.selectedQuality
            )
        )
    }
}

private struct PlaybackMenuState {
    var canPlayPrevious = false
    var canPlayNext = false
    var hasSubtitles = false
    var selectedQuality: QualityOption?

    static let noPlayer = PlaybackMenuState()
}

private struct PlaybackMenuItems: View {
    @ObservedObject var center: AppCommandCenter
    let state: PlaybackMenuState

    var body: some View {
        CommandButton(title: "Play/Pause", command: .playPause, center: center)
        CommandButton(
            title: "Skip Back 10 Seconds",
            command: .skip(seconds: -AppCommand.skipInterval),
            center: center
        )
        CommandButton(
            title: "Skip Forward 10 Seconds",
            command: .skip(seconds: AppCommand.skipInterval),
            center: center
        )
        Divider()
        CommandButton(
            title: "Previous Episode",
            command: .previousEpisode,
            center: center,
            isEnabled: state.canPlayPrevious
        )
        CommandButton(title: "Next Episode", command: .nextEpisode, center: center, isEnabled: state.canPlayNext)
        Divider()
        CommandButton(
            title: "Toggle Subtitles",
            command: .toggleSubtitles,
            center: center,
            isEnabled: state.hasSubtitles
        )
        CommandButton(title: "Mute", command: .toggleMute, center: center)
        // A disabled Menu does not disable its items in the menu bar, so
        // each item carries the state itself.
        Menu("Quality") {
            ForEach(QualityOption.standardTiers + QualityOption.lowBandwidthTiers) { quality in
                Button {
                    center.perform(.setQuality(quality))
                } label: {
                    if state.selectedQuality == quality {
                        Label(quality.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(quality.menuTitle)
                    }
                }
                .disabled(!center.isEnabled(.setQuality(quality)))
            }
        }
        Divider()
        CommandButton(title: "Full Screen", command: .toggleFullScreen, center: center)
        CommandButton(title: "Exit Full Screen or Close Player", command: .escape, center: center)
    }
}

extension CommandShortcut {
    var keyEquivalent: KeyEquivalent {
        switch key {
        case .space: return .space
        case .leftArrow: return .leftArrow
        case .rightArrow: return .rightArrow
        case .escape: return .escape
        case .character(let character): return KeyEquivalent(character)
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }
}

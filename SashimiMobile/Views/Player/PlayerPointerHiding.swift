import AVFoundation
import SwiftUI

/// When the Mac player hides the mouse pointer (#799), as QuickTime does:
/// only while the video plays with its controls tucked away and the pointer
/// resting over the player. Anything that wants the pointer (a pause, a menu,
/// the controls, another app in front) keeps it. iPhone and iPad have no
/// pointer to hide.
struct PlayerPointerState: Equatable {
    var isMac: Bool
    var isPlaying: Bool
    var controlsVisible: Bool
    var menuOpen: Bool
    var pointerInside: Bool
    var appActive: Bool

    var hidesPointer: Bool {
        isMac && appActive && isPlaying && !controlsVisible && !menuOpen && pointerInside
    }
}

/// The Mac's pointer handling for the player: moving the mouse reveals the
/// controls, and the pointer hides once they auto-hide during playback.
///
/// Hiding uses `NSCursor.setHiddenUntilMouseMoves`, so AppKit shows the
/// pointer again on the first movement whatever this view believes; it is
/// also shown explicitly whenever the policy turns, and when the player goes.
/// On iPhone and iPad this modifier changes nothing.
struct PlayerPointerHiding: ViewModifier {
    let player: AVPlayer?
    /// Any of the player's own UI on screen (controls, Up Next, loading).
    let controlsVisible: Bool
    /// The mouse moved over the player, a menu closed, or the app came back:
    /// the controls should come up (and the idle timer restart).
    let reveal: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var isPlaying = false
    /// Unknown until SwiftUI reports a hover, i.e. the mouse has not moved
    /// since the player opened; AppKit's pointer position answers until then.
    @State private var hover = Hover.unknown
    @State private var menuOpen = false

    func body(content: Content) -> some View {
#if targetEnvironment(macCatalyst)
        content
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    hover = .inside
                    reveal()
                case .ended:
                    hover = .outside
                }
            }
            // Menu bar menus and the player's pickers are NSMenus on the Mac.
            .onReceive(NotificationCenter.default.publisher(for: Self.menuBegan)) { _ in
                menuOpen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: Self.menuEnded)) { _ in
                menuOpen = false
                reveal()
            }
            .task(id: player.map(ObjectIdentifier.init)) {
                guard let player else {
                    isPlaying = false
                    return
                }
                for await status in player.publisher(for: \.timeControlStatus).values {
                    isPlaying = status != .paused
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { reveal() }
            }
            .onChange(of: hidesPointer) { _, hides in
                MacCursor.setHiddenUntilMouseMoves(hides)
            }
            .onDisappear {
                MacCursor.setHiddenUntilMouseMoves(false)
            }
#else
        content
#endif
    }

#if targetEnvironment(macCatalyst)
    private static let menuBegan = Notification.Name("NSMenuDidBeginTrackingNotification")
    private static let menuEnded = Notification.Name("NSMenuDidEndTrackingNotification")

    private var hidesPointer: Bool {
        PlayerPointerState(
            isMac: true,
            isPlaying: isPlaying,
            controlsVisible: controlsVisible,
            menuOpen: menuOpen,
            pointerInside: hover == .unknown ? MacCursor.isOverKeyWindow : hover == .inside,
            appActive: scenePhase == .active
        ).hidesPointer
    }
#endif

    private enum Hover {
        case unknown, inside, outside
    }
}

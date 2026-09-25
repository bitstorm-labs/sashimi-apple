import AVFoundation
import Combine

/// How the picture fills the screen. The names and the set of modes match the
/// Roku and Android clients, so a user sees the same three choices everywhere.
enum VideoViewMode: String, CaseIterable, Identifiable, Sendable {
    /// The whole picture at its own aspect ratio, with black bars where it
    /// does not match the screen.
    case normal
    /// Scaled uniformly until the bars are gone; the edges are cropped.
    case zoom
    /// Scaled to the screen in each direction separately; nothing is cropped
    /// and the picture is distorted.
    case stretch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .zoom: return "Zoom"
        case .stretch: return "Stretch"
        }
    }

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .normal: return .resizeAspect
        case .zoom: return .resizeAspectFill
        case .stretch: return .resize
        }
    }

    var systemImage: String {
        switch self {
        case .normal: return "rectangle.arrowtriangle.2.inward"
        case .zoom: return "plus.magnifyingglass"
        case .stretch: return "arrow.left.and.right"
        }
    }
}

/// Which view mode a video opens in, and where a change from the player goes.
///
/// A mode chosen in the player lasts for the rest of the app session: later
/// videos, channel changes and rebuilt streams (quality, audio or subtitle
/// changes) all keep it. With no session choice a video opens in the saved
/// default. Setting a default is the newer, deliberate choice, so it replaces
/// any session choice rather than being hidden behind it.
@MainActor
final class VideoViewModeStore: ObservableObject {
    static let shared = VideoViewModeStore()

    static let defaultModeKey = "defaultVideoViewMode"

    private let defaults: UserDefaults

    /// The mode picked in the player this session, if any.
    @Published private(set) var sessionMode: VideoViewMode?

    /// The saved default, used when nothing was picked this session.
    @Published private(set) var defaultMode: VideoViewMode

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.defaultModeKey)
        // An unknown value (a mode a later build removed) falls back to Normal
        // rather than failing.
        defaultMode = stored.flatMap(VideoViewMode.init(rawValue:)) ?? .normal
    }

    /// The mode the picture should be in right now.
    var activeMode: VideoViewMode {
        sessionMode ?? defaultMode
    }

    /// A pick from the player: applies now and for the rest of the session.
    func choose(_ mode: VideoViewMode) {
        sessionMode = mode
    }

    /// "Use for All Videos": the active mode becomes the saved default.
    func useActiveModeForAllVideos() {
        setDefault(activeMode)
    }

    /// Saves `mode` as the default for every video, replacing any session pick.
    func setDefault(_ mode: VideoViewMode) {
        defaults.set(mode.rawValue, forKey: Self.defaultModeKey)
        defaultMode = mode
        sessionMode = nil
    }
}

import SwiftUI
import UIKit

/// The Mac window's size policy. Pure, so it is tested on any platform.
enum MacWindowMetrics {
    /// Below this the rail plus a two-column grid no longer fit.
    static let minimumSize = CGSize(width: 900, height: 600)
    /// The first-launch size. After that macOS restores whatever the window
    /// was last resized to (scene restoration persists the frame).
    static let defaultSize = CGSize(width: 1280, height: 800)

    /// `defaultSize` centred on the screen's usable area, shrunk to fit a
    /// small display but never below `minimumSize`.
    static func initialFrame(in screen: CGRect) -> CGRect {
        let width = max(minimumSize.width, min(defaultSize.width, screen.width))
        let height = max(minimumSize.height, min(defaultSize.height, screen.height))
        return CGRect(
            x: screen.minX + max(0, (screen.width - width) / 2),
            y: screen.minY + max(0, (screen.height - height) / 2),
            width: width,
            height: height
        )
    }
}

/// True on the Mac (Catalyst). The layout idiom is `.mac` there, so code that
/// asks "is this an iPad?" must use `MobileLayoutIdiom` instead.
enum MacPlatform {
    static var isMac: Bool {
#if targetEnvironment(macCatalyst)
        true
#else
        false
#endif
    }
}

/// Which mobile layout a device gets. The Mac (Catalyst, "Optimize for Mac")
/// reports the `.mac` idiom, not `.pad`, and gets the iPad layout: the icon
/// rail with content beside it, iPad detail pages and iPad player sizing.
enum MobileLayoutIdiom {
    static func usesPadLayout(_ idiom: UIUserInterfaceIdiom) -> Bool {
        idiom == .pad || idiom == .mac
    }

    @MainActor static var usesPadLayout: Bool {
        usesPadLayout(UIDevice.current.userInterfaceIdiom)
    }
}

#if targetEnvironment(macCatalyst)
/// Window chrome and full screen for the Catalyst window. UIKit exposes the
/// scene's size limits, title bar and full-screen state; toggling full screen
/// has no UIKit API, so it goes to the `NSWindow` (public AppKit API reached
/// dynamically, as Catalyst apps must).
@MainActor
enum MacWindow {
    private static let didSizeKey = "macWindow.didApplyDefaultSize"

    static func configure(_ scene: UIWindowScene) {
        scene.sizeRestrictions?.minimumSize = MacWindowMetrics.minimumSize
        // The rail is the app's chrome: no title text, toolbar strip or
        // separator over it. The content runs up under the traffic lights.
        scene.titlebar?.titleVisibility = .hidden
        scene.titlebar?.toolbar = nil
        scene.titlebar?.separatorStyle = .none

        // Only the very first window gets the default size; after that
        // AppKit restores the frame it autosaved (the size the user chose).
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didSizeKey) else { return }
        defaults.set(true, forKey: didSizeKey)
        let frame = MacWindowMetrics.initialFrame(in: scene.screen.bounds)
        scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.Mac(systemFrame: frame))
    }

    static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    static var isFullScreen: Bool {
        activeScene?.isFullScreen ?? false
    }

    static func toggleFullScreen() {
        guard let window = nsWindow else { return }
        _ = window.perform(NSSelectorFromString("toggleFullScreen:"), with: nil)
    }

    private static var nsWindow: NSObject? {
        guard let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = appClass.value(forKey: "sharedApplication") as? NSObject else { return nil }
        if let key = app.value(forKey: "keyWindow") as? NSObject { return key }
        if let main = app.value(forKey: "mainWindow") as? NSObject { return main }
        return (app.value(forKey: "windows") as? [NSObject])?.first
    }
}

/// Hands the hosting window's scene to `MacWindow.configure` once it exists.
private struct MacWindowConfigurator: UIViewRepresentable {
    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene {
                MacWindow.configure(scene)
            }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: Probe, context: Context) {}
}
#endif

extension View {
    /// Mac window setup (size limits, first-launch size, title bar); nothing
    /// on iPhone and iPad.
    @ViewBuilder
    func macWindowConfiguration() -> some View {
#if targetEnvironment(macCatalyst)
        background(MacWindowConfigurator().frame(width: 0, height: 0))
#else
        self
#endif
    }
}

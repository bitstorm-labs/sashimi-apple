import UIKit

#if targetEnvironment(macCatalyst)
import ObjectiveC

/// The Mac's mouse pointer, for the player. UIKit has no way to hide the
/// pointer on Catalyst (SwiftUI's `pointerVisibility` is macOS-only and
/// unavailable to iOS-family targets), so this reaches AppKit's public
/// `NSCursor` and `NSEvent` dynamically, as `MacWindow` does for the window.
@MainActor
enum MacCursor {
    /// `+[NSCursor setHiddenUntilMouseMoves:]`, QuickTime's mechanism: the
    /// pointer disappears now and AppKit itself brings it back the moment the
    /// mouse moves, so it cannot be left hidden. `false` shows it at once.
    static func setHiddenUntilMouseMoves(_ hidden: Bool) {
        guard let cursorClass = NSClassFromString("NSCursor") else { return }
        let selector = NSSelectorFromString("setHiddenUntilMouseMoves:")
        guard let method = class_getClassMethod(cursorClass, selector) else { return }
        typealias Setter = @convention(c) (AnyClass, Selector, Bool) -> Void
        let setter = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        setter(cursorClass, selector, hidden)
    }

    /// Whether the pointer is over the key window, read from AppKit. Used
    /// before SwiftUI has reported any hover (the mouse has not moved since
    /// the player opened). Screen coordinates on both sides.
    static var isOverKeyWindow: Bool {
        guard let eventClass = NSClassFromString("NSEvent") as? NSObject.Type,
              let location = (eventClass.value(forKey: "mouseLocation") as? NSValue)?.cgPointValue,
              let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = appClass.value(forKey: "sharedApplication") as? NSObject,
              let window = app.value(forKey: "keyWindow") as? NSObject,
              let frame = (window.value(forKey: "frame") as? NSValue)?.cgRectValue else { return false }
        return frame.contains(location)
    }
}
#endif

import SwiftUI
import UIKit
import XCTest
@testable import SashimiMobile

/// iPhone's Search tab shows its search field on open (#752). With the default
/// placement iOS hid it under the large title until the list was pulled down.
@MainActor
final class PhoneSearchFieldTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    func testTheSearchFieldIsAlwaysShown() throws {
        let controller = UIHostingController(rootView: NavigationStack { MobileSearchView() }.preferredColorScheme(.dark))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        let navigationItems = Self.viewControllers(from: controller)
            .map(\.navigationItem)
            .filter { $0.searchController != nil }
        let item = try XCTUnwrap(navigationItems.first, "Search installs a system search field")
        XCTAssertFalse(item.hidesSearchBarWhenScrolling, "the field stays in view instead of hiding under the title")

        if let directory = ProcessInfo.processInfo.environment["SASHIMI_RENDER_DIR"] {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("phone-search.png"))
        }
    }

    private static func viewControllers(from root: UIViewController) -> [UIViewController] {
        [root] + root.children.flatMap(viewControllers(from:))
            + (root.presentedViewController.map(viewControllers(from:)) ?? [])
    }
}

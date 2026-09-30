import SwiftUI
import UIKit
import XCTest
@testable import SashimiMobile

/// #126: on iPad the Search tab's query lives in MainNavigationView's header
/// field, so a Siri/App Intents search has to land in that shared query.
@MainActor
final class IPadHeaderSearchTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    func testInitialQueryIsNormalizedIntoTheHeaderOwnedQuery() {
        let box = QueryBox()
        let consumed = expectation(description: "initial query consumed")
        consumed.assertForOverFulfill = false

        host(
            NavigationStack {
                MobileSearchView(
                    initialQuery: "Search Sashimi for Alien",
                    onInitialQueryConsumed: { consumed.fulfill() },
                    query: box.binding
                )
            },
            size: CGSize(width: 820, height: 600)
        )

        wait(for: [consumed], timeout: 10)
        XCTAssertEqual(box.value, "Alien")
    }

    func testSiriSearchRequestFillsTheHeaderField() throws {
        let requestID = UUID()
        let consumed = expectation(description: "search request consumed")
        consumed.assertForOverFulfill = false

        let hosted = host(
            MainNavigationView(
                searchRequest: .init(id: requestID, query: "Search Sashimi for Alien"),
                onSearchRequestConsumed: { id in
                    if id == requestID { consumed.fulfill() }
                }
            ),
            size: CGSize(width: 1180, height: 820)
        )

        wait(for: [consumed], timeout: 10)
        spinRunLoop(seconds: 0.5)

        let fields = hosted.view.allSubviews(ofType: UITextField.self)
        let field = try XCTUnwrap(fields.first, "The Search tab should put a text field in the header")
        XCTAssertEqual(fields.count, 1, "iPad Search should show only the header field, not .searchable")
        XCTAssertEqual(field.text, "Alien")
        XCTAssertEqual(field.placeholder ?? field.attributedPlaceholder?.string, HeaderSearchField.placeholder)

        saveRender(of: hosted.view, named: "ipad-search-header-typed")
    }

    /// Writes a PNG only when SASHIMI_RENDER_DIR is set
    /// (`TEST_RUNNER_SASHIMI_RENDER_DIR=... xcodebuild test`), so CI skips it.
    func testRenderIdleHeader() throws {
        guard let directory = ProcessInfo.processInfo.environment["SASHIMI_RENDER_DIR"] else {
            throw XCTSkip("Set SASHIMI_RENDER_DIR to write header renders")
        }
        let consumed = expectation(description: "empty request consumed")
        consumed.assertForOverFulfill = false
        // An empty query still routes to the Search tab, leaving the
        // placeholder showing.
        let hosted = host(
            MainNavigationView(
                searchRequest: .init(id: UUID(), query: " "),
                onSearchRequestConsumed: { _ in consumed.fulfill() }
            ),
            size: CGSize(width: 1180, height: 820)
        )
        wait(for: [consumed], timeout: 10)
        spinRunLoop(seconds: 0.5)
        saveRender(of: hosted.view, named: "ipad-search-header-idle", directory: directory)
    }

    // MARK: - Helpers

    @discardableResult
    private func host<Content: View>(_ content: Content, size: CGSize) -> UIViewController {
        let controller = UIHostingController(rootView: content.preferredColorScheme(.dark))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
        spinRunLoop(seconds: 0.2)
        return controller
    }

    private func spinRunLoop(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func saveRender(of view: UIView, named name: String, directory: String? = nil) {
        guard let directory = directory ?? ProcessInfo.processInfo.environment["SASHIMI_RENDER_DIR"] else {
            return
        }
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        XCTAssertNoThrow(try image.pngData()?.write(to: url))
    }
}

/// A reference-typed query so the test can read what the view wrote.
private final class QueryBox {
    var value = ""
    var binding: Binding<String> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}

private extension UIView {
    func allSubviews<T: UIView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { subview -> [T] in
            let own: [T] = (subview as? T).map { [$0] } ?? []
            return own + subview.allSubviews(ofType: type)
        }
    }
}

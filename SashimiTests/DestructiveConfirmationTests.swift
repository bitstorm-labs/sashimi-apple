import XCTest
@testable import Sashimi

@MainActor
final class DestructiveConfirmationTests: XCTestCase {
    /// The remote starts on the alert's preferred action, so that has to be
    /// Cancel and never the destructive button (#576).
    func testCancelIsThePreferredAction() {
        let alert = DestructiveConfirmationAlert.make(
            title: "Delete Solstice?",
            message: "The channel is removed from every device.",
            confirmTitle: "Delete Channel",
            onConfirm: {},
            onCancel: {}
        )

        XCTAssertEqual(alert.preferredAction?.style, .cancel)
        XCTAssertEqual(alert.preferredAction?.title, "Cancel")
        XCTAssertEqual(alert.actions.map(\.title), ["Delete Channel", "Cancel"])
        XCTAssertEqual(alert.actions.first?.style, .destructive)
    }
}

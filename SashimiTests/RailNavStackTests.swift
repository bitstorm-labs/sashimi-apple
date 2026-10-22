import SwiftUI
import UIKit
import XCTest
@testable import Sashimi

/// The rail's nav rows must fit the height they are given. With a fixed 26pt
/// gap, a server with enough libraries made the rail taller than the screen,
/// and the root ZStack centred it, pushing the whole UI up (Anime library,
/// 2026-10-22: ten rows).
@MainActor
final class RailNavStackTests: XCTestCase {
    private struct Row: Identifiable { let id: Int }

    /// Same height as a collapsed rail row: a 28pt glyph line plus 2×11 padding.
    private let rowHeight: CGFloat = 56

    private func measuredHeight(rows: Int, proposed: CGFloat) -> CGFloat {
        let height = rowHeight
        let stack = RailNavStack(data: (0..<rows).map(Row.init)) { _ in
            Color.clear.frame(width: 44, height: height)
        }
        let host = UIHostingController(rootView: stack)
        return host.sizeThatFits(in: CGSize(width: 120, height: proposed)).height
    }

    func testLongNavShrinksToFitTheSpaceItIsGiven() {
        // Ten rows at a 26pt gap need 794pt; the rail leaves about 630.
        XCTAssertLessThanOrEqual(measuredHeight(rows: 10, proposed: 630), 630)
    }

    func testNavKeepsItsFullGapWhenThereIsRoom() {
        let rows = 6
        let full = CGFloat(rows) * rowHeight + CGFloat(rows - 1) * RailNavSpacing.max
        XCTAssertEqual(measuredHeight(rows: rows, proposed: 900), full, accuracy: 0.5)
    }

    func testGapNeverClosesBelowTheMinimum() {
        let rows = 14
        let tightest = CGFloat(rows) * rowHeight + CGFloat(rows - 1) * RailNavSpacing.min
        XCTAssertGreaterThanOrEqual(measuredHeight(rows: rows, proposed: 300), tightest - 0.5)
    }
}

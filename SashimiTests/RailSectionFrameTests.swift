import SwiftUI
import UIKit
import XCTest
@testable import Sashimi

/// The rail must never be taller than the screen, whatever the section beside
/// it asks for (#751): Search with a full recent-search list asked for 1156pt,
/// the root ZStack grew to match and the rail's flexible gaps stretched.
@MainActor
final class RailSectionFrameTests: XCTestCase {
    private let screen = CGSize(width: 1920, height: 1080)

    private func height<V: View>(_ view: V) -> CGFloat {
        UIHostingController(rootView: view).sizeThatFits(in: screen).height
    }

    /// The root's shape: a section, and the rail at full height beside it.
    private func root<Section: View>(_ section: Section) -> some View {
        ZStack(alignment: .topLeading) {
            section
            Color.clear.frame(width: 120).frame(maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }

    func testATallSectionNoLongerStretchesTheRoot() {
        let tall = Color.blue.frame(height: 1400)
        XCTAssertEqual(height(root(tall)), 1400, "unpinned, the root grows with its tallest child")
        XCTAssertEqual(height(root(tall.railSectionFrame(height: 1080))), 1080)
    }

    func testSearchFitsTheScreenWithAFullRecentHistory() {
        let saved = UserDefaults.standard.stringArray(forKey: "searchHistory")
        defer {
            UserDefaults.standard.set(saved, forKey: "searchHistory")
        }
        for query in ["alien", "batman", "cosmos", "dune", "expanse", "fargo"] {
            SearchHistoryManager.shared.addSearch(query)
        }
        XCTAssertLessThanOrEqual(height(SearchView()), 1080)
    }
}

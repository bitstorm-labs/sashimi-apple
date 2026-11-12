import XCTest
@testable import Sashimi

/// The side menu lists its destinations in Home's row order (#861): whatever
/// order the rows are in, whatever was saved for the menu-only entries, the
/// destinations that rows stand for come out of the menu in exactly the rows'
/// relative order. Menu-only entries (Lists, Dashboard, libraries Home has no
/// row for) may sit anywhere among them, but never reorder them.
@MainActor
final class MenuFollowsRowOrderTests: XCTestCase {
    private let suite = "MenuFollowsRowOrderTests"
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private let libraryIds = ["movies", "tv", "boxsets"]
    private let all: [RailOrder.Destination] = [.requests, .dashboard]

    private let rows: [HomeRowConfig] = [
        .builtIn(.hero),
        .builtIn(.continueWatching),
        .builtIn(.requests),
        .builtIn(.channels),
        .library(id: "movies", name: "Movies"),
        .library(id: "tv", name: "TV Shows", visible: false),
        .list(id: "abc", title: "From Chad: Halloween")
    ]

    /// Saved menu orders worth throwing at it: none, Lists and a menu-only
    /// library moved to the top, and a stale #845 `menu:requests` key.
    private let savedOrders: [[String]?] = [
        nil,
        ["menu:lists", "menu:library:boxsets", "menu:dashboard"],
        ["menu:requests", "menu:dashboard", "channels", "menu:lists"],
        ["library_tv", "menu:requests", "library_movies", "menu:library:boxsets", "menu:lists"]
    ]

    private func assertMenuFollowsRows(
        _ rows: [HomeRowConfig],
        saved: [String]?,
        available: [RailOrder.Destination],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let menu = RailOrder.destinations(rowConfigs: rows, libraryIds: libraryIds, savedOrder: saved, available: available)
        let standsFor = rows.compactMap(\.railDestination).filter { destination in
            switch destination {
            case .requests, .dashboard, .watchlist: return available.contains(destination)
            case .library(let id): return libraryIds.contains(id)
            case .finTV, .lists: return true
            }
        }
        XCTAssertEqual(menu.filter(standsFor.contains), standsFor,
                       "rows \(rows.map(\.id)) saved \(saved ?? [])", file: file, line: line)
        XCTAssertEqual(Set(menu).count, menu.count, "each destination once", file: file, line: line)
    }

    func testEveryRowOrderGivesTheSameMenuOrder() {
        var count = 0
        for order in permutations(of: rows) {
            for saved in savedOrders {
                for available in [all, [], [.dashboard]] {
                    assertMenuFollowsRows(order, saved: saved, available: available)
                    count += 1
                }
            }
        }
        XCTAssertEqual(count, 5040 * 4 * 3)
    }

    /// The same through Settings: a run of moves, each saved the way the
    /// Home & Side Menu screen saves it, menu-only entries included.
    func testMovesInSettingsKeepTheMenuInRowOrder() {
        let settings = HomeScreenSettings(defaults: defaults)
        settings.rowConfigs = rows
        settings.saveSettings()
        var generator = SplitMix(seed: 861)
        for step in 0..<400 {
            let available = step.isMultiple(of: 5) ? [] : all
            let entries = settings.sideMenuEntries(libraryIds: libraryIds, available: available)
            let from = Int(generator.next() % UInt64(entries.count))
            let to = Int(generator.next() % UInt64(entries.count + 1))
            settings.applySideMenuOrder(SideMenuOrder.moving(entries, from: [from], to: to))
            assertMenuFollowsRows(settings.rowConfigs, saved: settings.sideMenuOrder, available: all)
            assertMenuFollowsRows(settings.rowConfigs, saved: settings.sideMenuOrder, available: available)
            XCTAssertEqual(Set(settings.rowConfigs.map(\.id)), Set(rows.map(\.id)), "no row lost or gained")
        }
    }

    private func permutations<T>(of items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(of: rest).map { [head] + $0 }
        }
    }
}

/// A seeded generator so a failing run can be replayed.
private struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
